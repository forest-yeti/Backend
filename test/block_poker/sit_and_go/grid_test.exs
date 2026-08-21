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
      for seats <- [2, 3, 6] do
        assert PrizePool.valid_chances?(Grid.prize_tiers(seats)),
               "таблица #{seats}-max не суммируется в #{PrizePool.chance_scale()}"
      end
    end

    test "возврат игроку равен целевым 93% для обеих рассадок" do
      for seats <- [2, 3, 6] do
        assert PrizePool.expected_return_ppm(Grid.prize_tiers(seats), seats) ==
                 Grid.target_return_ppm()
      end
    end

    test "матожидание множителя — это число мест, умноженное на возврат" do
      assert PrizePool.expected_multiplier_ppm(Grid.prize_tiers(2)) == 1_860_000
      assert PrizePool.expected_multiplier_ppm(Grid.prize_tiers(3)) == 2_790_000
      assert PrizePool.expected_multiplier_ppm(Grid.prize_tiers(6)) == 5_580_000
    end

    test "таблица чужой рассадки ломает экономику — потому у каждой своя" do
      # Таблица 3-max за столом на двоих раздаёт 2.79 взноса при двух
      # собранных. Проверка существует, чтобы «переиспользовать таблицу»
      # не выглядело безобидной экономией.
      assert PrizePool.expected_return_ppm(Grid.prize_tiers(3), 2) == 1_395_000
      assert PrizePool.expected_return_ppm(Grid.prize_tiers(6), 3) == 1_860_000
    end

    test "у 2-max основной множитель ниже x2 — этого требует матожидание" do
      # E[множитель] обязано равняться 1.86, поэтому модальный тир не может
      # быть x2 или выше: иначе возврат превысил бы договорённый.
      modal = Enum.max_by(Grid.prize_tiers(2), & &1.chance_ppm)

      assert modal.multiplier < 200
    end

    test "ни один тир не оплачивает мест больше, чем игроков за столом" do
      for seats <- [2, 3, 6], tier <- Grid.prize_tiers(seats) do
        assert length(tier.payouts) <= seats
      end
    end

    test "доли мест складываются в сотню и идут по убыванию" do
      for seats <- [2, 3, 6], tier <- Grid.prize_tiers(seats) do
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

  describe "потолок выплаты" do
    test "ни один стол сетки не может выплатить больше потолка" do
      for row <- Grid.expand(), tier <- row.tiers do
        prize = PrizePool.prize_pool(row.attrs.buy_in, tier.multiplier)

        assert prize <= Grid.max_prize(),
               "#{row.attrs.name}: #{PrizePool.multiplier_label(tier.multiplier)} даёт #{prize}"
      end
    end

    test "обрезка сохраняет возврат ровно, а не примерно" do
      # Главное свойство: RTP сходится по построению для каждой пары
      # «рассадка × взнос», а не подобран для одной таблицы.
      for row <- Grid.expand() do
        assert PrizePool.valid_chances?(row.tiers)

        assert PrizePool.expected_return_ppm(row.tiers, row.attrs.max_players) ==
                 Grid.target_return_ppm(),
               "экономика разъехалась: #{row.attrs.name}"
      end
    end

    test "микролимиты не задеты: там джекпот и так мал" do
      # x10000 при взносе $0.25 — это $2500, обрезать нечего.
      assert Grid.prize_tiers(3, 25) == Grid.prize_tiers(3)
      assert Grid.prize_tiers(3, 100) == Grid.prize_tiers(3)
    end

    test "на высоких лимитах хвост отрезан" do
      top = fn buy_in -> 3 |> Grid.prize_tiers(buy_in) |> Enum.max_by(& &1.multiplier) end

      assert top.(1_000).multiplier == 100_000
      assert top.(10_000).multiplier == 10_000
    end

    test "шансы отрезанных тиров переезжают в верхний выживший" do
      base = Grid.prize_tiers(3)
      capped = Grid.prize_tiers(3, 10_000)

      dropped =
        base
        |> Enum.filter(&(&1.multiplier > 10_000))
        |> Enum.reduce(0, &(&1.chance_ppm + &2))

      был = Enum.find(base, &(&1.multiplier == 10_000)).chance_ppm
      стал = Enum.find(capped, &(&1.multiplier == 10_000)).chance_ppm

      # Редкое событие остаётся таким же редким, меняется только его размер.
      assert стал == был + dropped
    end

    test "предельный множитель выводится из потолка, а не задан списком" do
      assert Grid.max_multiplier(10_000) == 10_000
      assert Grid.max_multiplier(1_000) == 100_000
      assert Grid.max_multiplier(100) == 1_000_000
    end
  end

  describe "тестовый стол" do
    test "живёт только на игровых фишках" do
      # Возврат здесь в сотни раз выше собранного: на реальных деньгах
      # это была бы раздача денег.
      assert Grid.test_row().attrs.currency == :play_money
    end

    test "джекпот выпадает часто — иначе путь не проверить" do
      tiers = Grid.test_row().tiers
      jackpot = Enum.max_by(tiers, & &1.multiplier)

      assert jackpot.multiplier == 1_000_000
      assert jackpot.chance_ppm >= 100_000
    end

    test "шансы сходятся: сломан возврат, а не таблица" do
      assert PrizePool.valid_chances?(Grid.test_row().tiers)
    end

    test "в боевую сетку не входит и под проверку экономики не попадает" do
      names = Grid.expand() |> Enum.map(& &1.attrs.name)

      refute Grid.test_row().attrs.name in names
    end

    test "имя помечено как тестовое" do
      assert String.starts_with?(Grid.test_row().attrs.name, "ТЕСТ")
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
    test "полная сетка — четыре взноса на две дисциплины, три рассадки и две валюты" do
      assert length(Grid.expand()) == 48
    end

    test "каждая рассадка представлена в обеих дисциплинах и обеих валютах" do
      by_seats = Grid.expand() |> Enum.group_by(& &1.attrs.max_players)

      assert Map.keys(by_seats) |> Enum.sort() == [2, 3, 6]

      for {_seats, rows} <- by_seats do
        assert length(rows) == 16
        assert rows |> Enum.map(& &1.attrs.game_type) |> Enum.uniq() |> length() == 2
        assert rows |> Enum.map(& &1.attrs.currency) |> Enum.uniq() |> length() == 2
      end
    end

    test "каждый шаблон приходит со своей структурой и таблицей" do
      for row <- Grid.expand() do
        assert row.levels != []
        assert PrizePool.valid_chances?(row.tiers)

        # Тиров восемь у нетронутых таблиц и меньше у обрезанных: на $100
        # верхних двух не существует.
        assert length(row.tiers) in 6..8
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
      rows = Grid.expand(currency: :main, game_type: :short_deck, max_players: 2)

      assert length(rows) == 4
      assert Enum.all?(rows, &(&1.attrs.currency == :main))
      assert Enum.all?(rows, &(&1.attrs.max_players == 2))
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
