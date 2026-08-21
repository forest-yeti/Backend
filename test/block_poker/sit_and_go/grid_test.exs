defmodule BlockPoker.SitAndGo.GridTest do
  @moduledoc """
  Экономика стандартной сетки — то, ради чего таблицы призов живут в коде.

  Тест сторожит договор: сетка возвращает игрокам ровно 93% взносов, и
  правка любого веса, которая это ломает, обязана падать здесь, а не
  обнаруживаться по отчёту через месяц.

  БД не нужна: `Grid.expand/1` — чистая функция.
  """

  use ExUnit.Case, async: true

  alias BlockPoker.Engine.PrizePool
  alias BlockPoker.SitAndGo.Grid

  describe "таблицы призов" do
    test "шансы каждой таблицы складываются в полную шкалу" do
      for seats <- [3, 6] do
        assert PrizePool.valid_chances?(Grid.prize_tiers(seats)),
               "таблица #{seats}-max не суммируется в #{PrizePool.chance_scale()}"
      end
    end

    test "возврат игроку равен целевым 93% для обеих рассадок" do
      for seats <- [3, 6] do
        assert PrizePool.expected_return_ppm(Grid.prize_tiers(seats), seats) ==
                 Grid.target_return_ppm()
      end
    end

    test "матожидание множителя — это число мест, умноженное на возврат" do
      assert PrizePool.expected_multiplier_ppm(Grid.prize_tiers(3)) == 2_790_000
      assert PrizePool.expected_multiplier_ppm(Grid.prize_tiers(6)) == 5_580_000
    end

    test "ни один тир не оплачивает мест больше, чем игроков за столом" do
      for seats <- [3, 6], tier <- Grid.prize_tiers(seats) do
        assert length(tier.payouts) <= seats
      end
    end

    test "доли мест складываются в сотню и идут по убыванию" do
      for seats <- [3, 6], tier <- Grid.prize_tiers(seats) do
        assert Enum.sum(tier.payouts) == 100
        assert tier.payouts == Enum.sort(tier.payouts, :desc)
        assert Enum.all?(tier.payouts, &(&1 > 0))
      end
    end

    test "мелкие множители забирает победитель целиком" do
      # На x2 за столом на троих доля второго места была бы меньше взноса.
      tier = Enum.min_by(Grid.prize_tiers(3), & &1.multiplier)

      assert tier.payouts == [100]
    end

    test "крупный множитель делится между местами" do
      tier = Enum.max_by(Grid.prize_tiers(3), & &1.multiplier)

      assert length(tier.payouts) > 1
    end
  end

  describe "структуры уровней" do
    test "холдем играется на блайндах" do
      levels = Grid.blind_levels(:texas_holdem)

      assert Enum.all?(levels, &(&1.big_blind > 0))
      assert Enum.all?(levels, &(&1.ante == 0))
    end

    test "Short Deck играется на анте: блайндов у него нет вовсе" do
      levels = Grid.blind_levels(:short_deck)

      assert Enum.all?(levels, &(&1.ante > 0))
      assert Enum.all?(levels, &(&1.big_blind == 0 and &1.small_blind == 0))
    end

    test "номиналы растут, а нумерация идёт подряд с первого" do
      for game_type <- [:texas_holdem, :short_deck] do
        levels = Grid.blind_levels(game_type)

        assert Enum.map(levels, & &1.level) == Enum.to_list(1..length(levels))

        units = Enum.map(levels, &max(&1.big_blind, &1.ante))
        assert units == Enum.sort(units)
        assert units == Enum.uniq(units)
      end
    end

    test "первый уровень даёт играбельный стек" do
      # Гипер начинается с 25 больших блайндов: меньше — это уже не турнир,
      # а один пуш вслепую.
      level = Grid.blind_levels(:texas_holdem) |> hd()

      assert div(Grid.starting_stack(), level.big_blind) == 25
    end
  end

  describe "expand/1" do
    test "полная сетка — четыре взноса на две дисциплины, рассадки и валюты" do
      assert length(Grid.expand()) == 32
    end

    test "каждый шаблон приходит со своей структурой и таблицей" do
      for row <- Grid.expand() do
        assert row.levels != []
        assert PrizePool.valid_chances?(row.tiers)
        assert length(row.tiers) == 8
      end
    end

    test "естественные ключи сетки уникальны" do
      keys =
        Enum.map(
          Grid.expand(),
          &{&1.attrs.game_type, &1.attrs.currency, &1.attrs.buy_in, &1.attrs.max_players}
        )

      assert length(Enum.uniq(keys)) == length(keys)
    end

    test "опции сужают выборку, не меняя её формы" do
      rows = Grid.expand(currency: :main, game_type: :short_deck, max_players: 3)

      assert length(rows) == 4
      assert Enum.all?(rows, &(&1.attrs.currency == :main))
      assert Enum.all?(rows, &(&1.attrs.max_players == 3))
    end

    test "взносы заданы в минимальных единицах" do
      buy_ins =
        Grid.expand(currency: :main, game_type: :texas_holdem, max_players: 3)
        |> Enum.map(& &1.attrs.buy_in)
        |> Enum.sort()

      # $0.25, $1, $10, $100.
      assert buy_ins == [25, 100, 1_000, 10_000]
    end
  end
end
