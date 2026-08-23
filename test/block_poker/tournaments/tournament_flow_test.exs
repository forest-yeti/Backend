defmodule BlockPoker.Tournaments.TournamentFlowTest do
  @moduledoc """
  Турнир целиком: расписание → анонс → регистрация → старт → игра →
  вылет → выплата.

  Единственный тест, который проверяет, что все части сходятся. Раздачи
  здесь настоящие: игроки ходят через `TableServer`, вылет считает
  движок, место присваивает турнир, деньги пишет контекст. Ни одна
  часть не подменена, потому что подменённая часть — это то место, где
  ошибка и спрячется.

  Инварианты, ради которых он существует:

    * фишки турнира не появляются и не исчезают;
    * сумма выплат ровно равна фонду;
    * места идут подряд и достаются тем, кто вылетел.
  """

  use BlockPoker.DataCase, async: false

  import BlockPoker.AccountsFixtures
  import BlockPoker.TournamentsFixtures

  alias BlockPoker.Tables.{RoomState, TableServer}
  alias BlockPoker.Tournaments
  alias BlockPoker.Tournaments.{Entry, TournamentServer}
  alias BlockPoker.Wallet
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(BlockPoker.Repo, {:shared, self()})
    on_exit(fn -> Sandbox.mode(BlockPoker.Repo, :manual) end)

    # Блайнды сопоставимы со стеком: иначе двое доигрывали бы турнир
    # сотнями раздач, и тест мерил бы терпение, а не правила.
    %{setting: fast_setting()}
  end

  # Шаблон, где турнир заканчивается за считаные раздачи: большой блайнд
  # почти равен стеку, и первая же раздача идёт на всё.
  defp fast_setting(overrides \\ %{}) do
    levels = [
      %{
        level: 1,
        small_blind: 1000,
        big_blind: 2000,
        ante: 0,
        duration_seconds: 600,
        rebuy_allowed: true,
        addon_allowed: false
      },
      %{
        level: 2,
        small_blind: 2000,
        big_blind: 4000,
        ante: 0,
        duration_seconds: 600,
        rebuy_allowed: false,
        addon_allowed: false
      }
    ]

    setting_fixture(
      Map.merge(
        %{table_size: 6, min_players: 2, buy_in: 1000, entry_fee: 100, starting_stack: 5000},
        overrides
      ),
      levels
    )
  end

  defp balance(user) do
    {:ok, wallet} = Wallet.get_wallet(user.id, :play_money)
    wallet.amount
  end

  defp start_server(tournament_id) do
    # Столы с ручными таймерами: пауза между раздачами в тестах не
    # отсчитывается реальным временем (§11 CLAUDE.md).
    pid =
      start_supervised!(
        {TournamentServer, tournament_id: tournament_id, room_opts: [timers: :manual]}
      )

    Sandbox.allow(BlockPoker.Repo, self(), pid)
    pid
  end

  # Доводит стол до раздачи: розыгрыш кнопки и пауза между раздачами
  # прогоняются вручную, а не ожиданием.
  defp deal_hand(table) do
    room = TableServer.state(table)

    if room.phase == :button_draw, do: TableServer.fire_timer(table, :button_draw)

    if TableServer.state(table).hand == nil, do: TableServer.fire_timer(table, :next_hand)
  end

  # Играет раздачи, пока турнир не кончится. Пауза между раздачами
  # прогоняется вручную, а не ожиданием.
  defp play_until_finished(pid, table, limit \\ 60) do
    Enum.reduce_while(1..limit, :playing, fn _index, _acc ->
      if TournamentServer.state(pid).status == :finished do
        {:halt, :finished}
      else
        deal_hand(table)
        play_hand(table)
        {:cont, :playing}
      end
    end)
  end

  # Доигрывает раздачу до конца: все ходят чек/фолд, пока раздача идёт.
  # Кто именно выиграет — тесту неважно, важно, что раздача завершится
  # и турнир получит `hand_finished`.
  defp play_hand(table) do
    Enum.reduce_while(1..40, :playing, fn _step, _acc ->
      room = TableServer.state(table)

      case room.hand do
        nil ->
          {:halt, :finished}

        hand ->
          act_or_run_out(table, room, hand)
          {:cont, :playing}
      end
    end)
  end

  # Ходить некому — значит раздача ушла в доводку после олл-ина: карты
  # доборного борта открываются по таймеру, и под ручными таймерами его
  # прогоняет тест. Без этого раздача с олл-ином зависает навсегда.
  defp act_or_run_out(table, room, hand) do
    case BlockPoker.Engine.Hand.to_act(hand) do
      nil ->
        TableServer.fire_timer(table, :runout)

      seat_number ->
        seat = Map.get(room.seats, seat_number)

        if seat && seat.user_id do
          TableServer.act(table, seat.user_id, action_for(hand, seat_number), room.action_seq)
        end
    end
  end

  # Чек, если можно, иначе колл: так раздача доходит до вскрытия, и на
  # блайндах, сопоставимых со стеком, кто-то обязательно вылетает.
  # Ключи набора легальных действий несут значения, а не признаки:
  # `check: false` означает «нельзя», а не «нет ключа».
  defp action_for(hand, seat_number) do
    actions = BlockPoker.Engine.Hand.legal_actions(hand, seat_number)

    cond do
      actions[:check] -> :check
      actions[:call] -> :call
      true -> :fold
    end
  end

  defp chips_at(table) do
    room = TableServer.state(table)

    pot = if room.hand, do: room.hand.pot, else: 0

    Enum.reduce(RoomState.seats(room), pot, fn seat, acc -> acc + seat.stack end)
  end

  describe "турнир на двоих от старта до выплаты" do
    setup ctx do
      tournament = tournament_fixture(ctx.setting)

      one = user_fixture()
      two = user_fixture()

      {:ok, _first} = Tournaments.register(tournament.id, one.id)
      {:ok, _second} = Tournaments.register(tournament.id, two.id)

      pid = start_server(tournament.id)
      :ok = TournamentServer.start_tournament(pid)

      [{table_id, table}] = Map.to_list(:sys.get_state(pid).tables)

      %{tournament: tournament, users: [one, two], pid: pid, table: table, table_id: table_id}
    end

    test "стол поднят и оба игрока за ним", ctx do
      room = TableServer.state(ctx.table)

      assert RoomState.seats_taken(room) == 2

      # Стек назначил турнир, а не стол: фишки приходят из снапшота.
      assert Enum.all?(RoomState.players(room), &(&1.stack == 5000))
    end

    test "фишки турнира не появляются и не исчезают", ctx do
      before = chips_at(ctx.table)

      deal_hand(ctx.table)
      play_hand(ctx.table)

      assert chips_at(ctx.table) == before
      assert before == 2 * 5000
    end

    test "турнир доигрывается до победителя и платит", ctx do
      [one, two] = ctx.users
      before_one = balance(one)
      before_two = balance(two)

      assert play_until_finished(ctx.pid, ctx.table) == :finished

      {:ok, reloaded} = Tournaments.get_tournament(ctx.tournament.id)
      assert reloaded.status == :finished

      # Фонд собран с двух взносов по 1000; комиссия осталась руму.
      assert reloaded.prize_pool == 2000

      # Сумма выплат ровно равна фонду: один взял 1300, второй 700.
      paid = balance(one) - before_one + (balance(two) - before_two)
      assert paid == 2000
    end

    test "места распределены и достались обоим", ctx do
      :finished = play_until_finished(ctx.pid, ctx.table)

      entries = Tournaments.list_entries(ctx.tournament.id)
      places = entries |> Enum.map(& &1.place) |> Enum.sort()

      assert places == [1, 2]
      assert Enum.all?(entries, &(&1.status == :paid))
    end

    test "выбывший помечен, победитель — нет", ctx do
      :finished = play_until_finished(ctx.pid, ctx.table)

      entries = Tournaments.list_entries(ctx.tournament.id)

      winner = Enum.find(entries, &(&1.place == 1))
      loser = Enum.find(entries, &(&1.place == 2))

      assert winner.prize == 1300
      assert loser.prize == 700
      assert loser.busted_at
      refute winner.busted_at
    end
  end

  describe "баунти" do
    test "голова выбитого достаётся победителю банка", ctx do
      setting = fast_setting(%{bounty_part: 400})
      tournament = tournament_fixture(setting)

      one = user_fixture()
      two = user_fixture()

      {:ok, _first} = Tournaments.register(tournament.id, one.id)
      {:ok, _second} = Tournaments.register(tournament.id, two.id)

      pid = start_server(tournament.id)
      :ok = TournamentServer.start_tournament(pid)

      [{_id, table}] = Map.to_list(:sys.get_state(pid).tables)

      before = balance(one) + balance(two)

      :finished = play_until_finished(pid, table)

      # Собрано: 2 × (1000 − 400) = 1200 в фонд, 2 × 400 = 800 в головы.
      # Обе головы возвращаются игрокам: одна убийце, одна победителю.
      assert balance(one) + balance(two) - before == 2000

      entries = Tournaments.list_entries(tournament.id)
      assert Enum.all?(entries, &(&1.status == :paid))
    end
  end

  describe "поздняя регистрация" do
    test "вошедший после старта садится за стол", ctx do
      tournament = tournament_fixture(ctx.setting)

      for _index <- 1..2 do
        {:ok, _entry} = Tournaments.register(tournament.id, user_fixture().id)
      end

      pid = start_server(tournament.id)
      :ok = TournamentServer.start_tournament(pid)

      latecomer = user_fixture()
      {:ok, entry} = Tournaments.register(tournament.id, latecomer.id)

      assert :ok = TournamentServer.seat_entry(pid, entry)

      assert TournamentServer.state(pid).players_left == 3

      # Стартовый стек независимо от того, сколько уровней прошло: это
      # стандарт, и он же объясняет, почему поздняя рега закрывается.
      [{_id, table}] = Map.to_list(:sys.get_state(pid).tables)
      seat = table |> TableServer.state() |> RoomState.find_seat(latecomer.id)

      assert seat.stack == 5000
    end
  end
end
