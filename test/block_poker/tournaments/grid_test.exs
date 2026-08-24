defmodule BlockPoker.Tournaments.GridTest do
  @moduledoc """
  Сетка турниров рума — то, ради чего она живёт в коде.

  Тест сторожит договор: сетка выплат исполнима при любой явке, доли
  складываются ровно, структура уровней доигрываема, а правила семейств
  (ре-энтри по времени, отсутствие аддона, голова из взноса) не
  разъезжаются с тем, что обещано игроку в витрине.

  БД не нужна: сетка — чистые данные.
  """

  use ExUnit.Case, async: true

  alias BlockPoker.Engine.TournamentPayout
  alias BlockPoker.Tournaments.{BlindLevel, Grid}

  @structures [:hyper, :classic, :short, :deep, :dev]

  describe "структура уровней" do
    test "уровни идут подряд и заканчиваются закрытой регистрацией" do
      for structure <- @structures do
        levels = Enum.map(Grid.blind_levels(structure), &struct(BlindLevel, &1))

        assert BlindLevel.validate_set(levels, 0) == :ok,
               "структура #{structure} не проходит проверку набора"
      end
    end

    test "скорость меняет только длительность, но не номиналы" do
      classic = Grid.blind_levels(:classic)
      hyper = Grid.blind_levels(:hyper)

      assert Enum.map(classic, & &1.big_blind) == Enum.map(hyper, & &1.big_blind)
      assert hd(classic).duration_seconds == 600
      assert hd(hyper).duration_seconds == 300
    end

    test "окно ре-энтри задано временем: час у гипера, два часа у долгих" do
      open = fn structure ->
        structure |> Grid.blind_levels() |> Enum.count(& &1.rebuy_allowed)
      end

      # 3600 / 300 и 7200 / 600 — оба по двенадцать уровней, но за разное
      # время игры, и это ровно то, чем гипер отличается от классики.
      assert open.(:hyper) == 12
      assert open.(:classic) == 12
      assert open.(:deep) == 8
    end

    test "аддона нет ни в одной структуре" do
      for structure <- @structures, level <- Grid.blind_levels(structure) do
        refute level.addon_allowed
      end
    end

    test "короткая колода играется на анте, а не на блайндах" do
      levels = Grid.blind_levels(:short, :short_deck)

      assert Enum.all?(levels, &(&1.big_blind == 0 and &1.small_blind == 0))
      assert Enum.all?(levels, &(&1.ante > 0))
    end

    test "каждый уровень несёт чем платить" do
      for structure <- @structures, level <- Grid.blind_levels(structure) do
        assert level.big_blind > 0 or level.ante > 0
      end
    end

    test "номиналы не убывают" do
      blinds = Enum.map(Grid.blind_levels(:classic), & &1.big_blind)

      assert blinds == Enum.sort(blinds)
    end
  end

  describe "сетка выплат" do
    test "проходит проверку ядра для всей возможной явки" do
      rows = Enum.map(Grid.payouts(), &to_row/1)

      assert TournamentPayout.validate(rows, 2, 10_000) == :ok
    end

    test "сумма выплат равна фонду при любой явке" do
      rows = Enum.map(Grid.payouts(), &to_row/1)

      for entries <- [2, 5, 9, 10, 29, 30, 99, 100, 500] do
        payouts = TournamentPayout.compute(rows, entries, entries, 1_000_003)

        assert TournamentPayout.total(payouts) == 1_000_003,
               "фонд разошёлся при явке #{entries}"
      end
    end

    test "чем больше явка, тем больше оплачиваемых мест" do
      rows = Enum.map(Grid.payouts(), &to_row/1)

      places =
        for entries <- [5, 20, 50, 300], do: TournamentPayout.paid_places(rows, entries, entries)

      assert places == [2, 3, 6, 18]
      assert places == Enum.sort(places)
    end

    test "доля первого места падает с ростом явки" do
      rows = Enum.map(Grid.payouts(), &to_row/1)

      firsts =
        for entries <- [5, 20, 50, 300] do
          rows
          |> TournamentPayout.compute(entries, entries, 1_000_000)
          |> hd()
          |> Map.fetch!(:amount)
        end

      assert firsts == Enum.sort(firsts, :desc)
    end
  end

  describe "шаблоны" do
    test "разворачиваются по семействам и ценам" do
      rows = Grid.rows()

      # 5 + 7 + 3 + 5 + 7 + 7 + 1 боевых и четыре тестовых.
      assert length(Grid.rows(only: :main)) == 35
      assert length(Grid.rows(only: :play_money)) == 4
      assert length(rows) == 39
    end

    test "цена входа сходится с названием" do
      names = Map.new(Grid.rows(only: :main), &{&1.attrs.name, &1.attrs})

      assert %{buy_in: 90, entry_fee: 10} = names["Hyper For Us $1"]
      assert %{buy_in: 4550, entry_fee: 450} = names["Classic $50"]
      assert %{buy_in: 142_500, entry_fee: 7500} = names["Big High Roller $1500"]
    end

    test "комиссия не входит во взнос" do
      for row <- Grid.rows() do
        assert row.attrs.entry_fee > 0
        assert row.attrs.entry_fee < row.attrs.buy_in
      end
    end

    test "голова — половина взноса и только в баунти-семействах" do
      by_name = Map.new(Grid.rows(), &{&1.attrs.name, &1.attrs})

      assert by_name["Bounty Hunter Classic $10"].bounty_part == 450
      assert by_name["Bounty Hunter Classic $10"].bounty_progressive
      assert by_name["Classic $10"].bounty_part == 0
    end

    test "ре-энтри везде разрешены и не ограничены счётчиком" do
      for row <- Grid.rows() do
        assert row.attrs.rebuy_allowed
        assert row.attrs.max_rebuys == nil
        assert row.attrs.addon_cost == 0
      end
    end

    test "финальный стол одинаков во всей сетке" do
      finals =
        Grid.rows()
        |> Enum.map(&{&1.attrs.final_felt_color, &1.attrs.final_background_color})
        |> Enum.uniq()

      assert finals == [{"#6B5518", "#191206"}]
    end

    test "расписание разворачивается в запуски суток" do
      by_name = Map.new(Grid.rows(), &{&1.attrs.name, &1})

      assert length(by_name["Hyper For Us $1"].schedules) == 48
      assert length(by_name["Classic $1"].schedules) == 24
      assert length(by_name["High Roller Classic $250"].schedules) == 8
      assert length(by_name["Develop for us - Heads-Up"].schedules) == 1440

      assert [%{start_time: ~T[01:00:00], weekday: 6}] =
               by_name["Big High Roller $1500"].schedules
    end

    test "субботний мейджор появляется за шесть дней, остальные — за час" do
      by_name = Map.new(Grid.rows(), &{&1.attrs.name, &1.attrs})

      assert by_name["Big High Roller $1500"].registration_opens_before == 518_400
      assert by_name["Classic $1"].registration_opens_before == 3600

      # Гипер стартует каждые полчаса: окно шире шага запуска показало бы
      # в витрине два одинаковых турнира подряд.
      assert by_name["Hyper For Us $1"].registration_opens_before == 1800
    end

    test "тестовые шаблоны стартуют втроём и на игровые фишки" do
      for row <- Grid.rows(only: :play_money) do
        assert row.attrs.currency == :play_money
        assert row.attrs.min_players == 3
      end
    end

    test "имена уникальны: иначе естественный ключ схлопнул бы шаблоны" do
      names = Enum.map(Grid.rows(), & &1.attrs.name)

      assert names == Enum.uniq(names)
    end
  end

  defp to_row(row) do
    row
    |> Map.put(:ticket_id, nil)
    |> Map.put(:ticket_value, nil)
  end
end
