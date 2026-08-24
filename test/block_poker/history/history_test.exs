defmodule BlockPoker.HistoryTest do
  @moduledoc """
  Уровень 3: запись истории на настоящей MySQL под Sandbox.

  Мокать здесь нечего — проверяются ровно те гарантии, которые даёт база:
  unique-индексы, каскады внешних ключей, атомарность транзакции и
  сложение в `ON DUPLICATE KEY UPDATE`. Мок этих правил проверял бы мок.
  """

  use BlockPoker.DataCase, async: true

  import BlockPoker.AccountsFixtures
  import BlockPoker.HistoryFixtures
  import Ecto.Query

  alias BlockPoker.History

  alias BlockPoker.History.{
    HandAction,
    HandPlayer,
    HandRecord,
    PlayerStatsDaily,
    TournamentResult
  }

  describe "запись раздачи" do
    test "повторный persist той же раздачи не создаёт второй строки" do
      rows = holdem_rows(%{users: two_users()})

      assert {:ok, :written} = History.write(rows)
      assert {:ok, :already} = History.write(rows)

      assert Repo.aggregate(HandRecord, :count) == 1
      assert Repo.aggregate(HandPlayer, :count) == 2
      assert Repo.aggregate(HandAction, :count) == 3
    end

    test "агрегат после нескольких раздач совпадает с суммой по hand_players" do
      [winner, loser] = users = two_users()

      for _hand <- 1..3 do
        assert {:ok, :written} = History.write(holdem_rows(%{users: users}))
      end

      by_player =
        Repo.one(from p in HandPlayer, where: p.user_id == ^winner, select: sum(p.net))

      aggregate =
        Repo.one(
          from s in PlayerStatsDaily,
            where: s.user_id == ^winner and s.game_mode == :cash,
            select: %{net: sum(s.net), hands: sum(s.hands)}
        )

      # MySQL возвращает суммы `Decimal`, поэтому сравнение — по значению.
      assert Decimal.eq?(aggregate.net, by_player)
      assert Decimal.eq?(aggregate.hands, 3)

      # Строка дня одна на игрока и режим: инкремент складывает, а не
      # заводит вторую.
      assert Repo.aggregate(
               from(s in PlayerStatsDaily, where: s.user_id == ^loser),
               :count
             ) == 1
    end

    test "удаление раздачи уносит игроков и действия, не оставляя сирот" do
      rows = holdem_rows(%{users: two_users()})
      assert {:ok, :written} = History.write(rows)

      Repo.delete!(Repo.get!(HandRecord, rows.hand.id))

      assert Repo.aggregate(HandPlayer, :count) == 0
      assert Repo.aggregate(HandAction, :count) == 0
    end

    test "фишки не возникают и не исчезают: вложенное равно полученному плюс рейк" do
      rows = holdem_rows(%{users: two_users()})
      assert {:ok, :written} = History.write(rows)

      hand = Repo.get!(HandRecord, rows.hand.id)
      players = Repo.all(from p in HandPlayer, where: p.hand_id == ^hand.id)

      invested = Enum.reduce(players, 0, &(&1.invested + &2))
      won = Enum.reduce(players, 0, &(&1.won + &2))

      assert invested == won + hand.rake
    end

    test "сумма очков всех участников OFC-раздачи равна нулю" do
      rows = ofc_rows(%{users: two_users()})
      assert {:ok, :written} = History.write(rows)

      assert Enum.reduce(rows.players, 0, &(&1.points + &2)) == 0
      assert Enum.reduce(rows.players, 0, &(&1.net + &2)) == 0
    end
  end

  describe "турнирные результаты" do
    test "повторная запись того же entry_id не создаёт второй строки" do
      attrs = tournament_result(%{user_id: user_fixture().id})

      assert {:ok, :written} = History.write_tournament_result(attrs)

      # Гасит именно constraint БД: вторая вставка уходит в базу и
      # возвращается конфликтом, а не отсекается проверкой в коде.
      assert {:ok, :already} = History.write_tournament_result(attrs)

      assert Repo.aggregate(TournamentResult, :count) == 1
    end

    test "дозапись при завершении турнира не трогает уже записанных" do
      user = user_fixture()
      tournament_id = Ecto.UUID.generate()

      entries =
        for index <- 0..2 do
          tournament_result(%{
            user_id: user.id,
            tournament_id: tournament_id,
            entry_index: index,
            entry_kind: if(index == 0, do: :initial, else: :reentry)
          })
        end

      Enum.each(entries, &assert({:ok, :written} = History.write_tournament_result(&1)))

      # Повтор всей пачки — это и есть дозапись при `maybe_finish`.
      Enum.each(entries, &assert({:ok, :already} = History.write_tournament_result(&1)))

      assert Repo.aggregate(TournamentResult, :count) == 3
    end

    test "ROI считает все входы, средняя позиция — только последний" do
      user = user_fixture()
      tournament_id = Ecto.UUID.generate()

      # Три входа: два ранних вылета и финальный стол. ROI обязан учесть
      # три взноса, средняя позиция — только последний вход.
      for {index, place, prize} <- [{0, 80, 0}, {1, 40, 0}, {2, 2, 5000}] do
        History.write_tournament_result(
          tournament_result(%{
            user_id: user.id,
            tournament_id: tournament_id,
            entry_index: index,
            place: place,
            entrants: 90,
            prize: prize,
            itm: prize > 0
          })
        )
      end

      summary = History.tournament_summary(user.id)

      assert summary.entries == 3
      assert summary.tournaments == 1
      assert summary.cost == 3 * 1100
      assert summary.income == 5000
      assert summary.profit == 5000 - 3300

      # Место 2 из 90 — по последнему входу, а не среднее по трём.
      assert summary.average_place_ppm == div(2 * 1_000_000, 90)
    end

    test "отменённый турнир даёт строку с возвратом, и ROI её учитывает" do
      user = user_fixture()

      History.write_tournament_result(
        tournament_result(%{
          user_id: user.id,
          outcome: :cancelled,
          place: nil,
          refund: 1100,
          itm: false
        })
      )

      summary = History.tournament_summary(user.id)

      assert summary.cost == 1100
      assert summary.income == 1100
      assert summary.profit == 0

      # Мест в отменённом турнире нет, и в среднюю позицию он не входит.
      assert summary.average_place_ppm == nil
    end
  end

  describe "видимость карт" do
    test "добровольный показ после записи меняет видимость, вскрытую не трогает" do
      [winner, loser] = users = two_users()
      rows = holdem_rows(%{users: users})

      rows =
        put_in(rows.players, [
          %{Enum.at(rows.players, 0) | card_visibility: :showdown},
          Enum.at(rows.players, 1)
        ])

      assert {:ok, :written} = History.write(rows)
      assert {:ok, 1} = History.mark_voluntary(rows.hand.id, [winner, loser])

      assert visibility(rows.hand.id, winner) == :showdown
      assert visibility(rows.hand.id, loser) == :voluntary
    end
  end

  defp two_users, do: [user_fixture().id, user_fixture().id]

  defp visibility(hand_id, user_id) do
    Repo.one(
      from p in HandPlayer,
        where: p.hand_id == ^hand_id and p.user_id == ^user_id,
        select: p.card_visibility
    )
  end
end
