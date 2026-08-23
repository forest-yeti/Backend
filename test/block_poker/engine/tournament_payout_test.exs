defmodule BlockPoker.Engine.TournamentPayoutTest do
  @moduledoc """
  Расчёт призовых MTT. БД и процессов не нужно — модуль чистый.

  Главный тест здесь один и он property: **сумма выплат ровно равна
  фонду**. Расхождение в единицу означает, что деньги создались или
  пропали мимо журнала, и поймать это обязан CI, а не сверка отчётов
  через месяц.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BlockPoker.Engine.TournamentPayout

  @ppm 1_000_000

  defp money(entries_from, entries_to, place_from, place_to, share_ppm) do
    %{
      entries_from: entries_from,
      entries_to: entries_to,
      place_from: place_from,
      place_to: place_to,
      share_ppm: share_ppm,
      ticket_id: nil,
      ticket_value: nil
    }
  end

  defp ticket(entries_from, entries_to, place_from, place_to, id, value) do
    %{
      entries_from: entries_from,
      entries_to: entries_to,
      place_from: place_from,
      place_to: place_to,
      share_ppm: nil,
      ticket_id: id,
      ticket_value: value
    }
  end

  # Две полосы: до девяти входов платим два места, дальше четыре.
  defp grid do
    [
      money(2, 9, 1, 1, 650_000),
      money(2, 9, 2, 2, 350_000),
      money(10, nil, 1, 1, 500_000),
      money(10, nil, 2, 2, 300_000),
      money(10, nil, 3, 4, 100_000)
    ]
  end

  describe "фонд и гарантия" do
    test "без гарантии фонд равен собранному" do
      assert TournamentPayout.pool(50_000, 0) == %{prize_pool: 50_000, overlay: 0}
    end

    test "недобор до гарантии рум покрывает оверлеем" do
      assert TournamentPayout.pool(30_000, 50_000) == %{prize_pool: 50_000, overlay: 20_000}
    end

    test "перебор над гарантией оверлея не даёт" do
      assert TournamentPayout.pool(80_000, 50_000) == %{prize_pool: 80_000, overlay: 0}
    end

    test "фриролл: весь фонд — оверлей" do
      assert TournamentPayout.pool(0, 10_000) == %{prize_pool: 10_000, overlay: 10_000}
    end
  end

  describe "выбор полосы по явке" do
    test "явка выбирает свою полосу, а не соседнюю" do
      assert TournamentPayout.paid_places(grid(), 5, 5) == 2
      assert TournamentPayout.paid_places(grid(), 50, 50) == 4
    end

    test "последняя полоса открыта вверх" do
      assert TournamentPayout.paid_places(grid(), 10_000, 10_000) == 4
    end

    test "явка — это входы: 70 входов пятидесяти человек попадают в полосу 70" do
      # Полоса выбрана по входам, а число мест урезано по людям — но
      # здесь людей хватает, и урезания не происходит.
      assert TournamentPayout.paid_places(grid(), 70, 50) == 4
    end
  end

  describe "деление фонда" do
    test "доли раскладываются по местам в порядке убывания" do
      payouts = TournamentPayout.compute(grid(), 50, 50, 1_000_000)

      assert Enum.map(payouts, & &1.place) == [1, 2, 3, 4]
      assert Enum.map(payouts, & &1.amount) == [500_000, 300_000, 100_000, 100_000]
    end

    test "остаток от деления достаётся первому месту" do
      payouts = TournamentPayout.compute(grid(), 50, 50, 100_003)

      assert TournamentPayout.total(payouts) == 100_003
      # 500_000ppm от 100_003 — это 50_001 плюс два «лишних» цента.
      assert hd(payouts).amount == 50_003
    end

    test "выплата не возрастает с местом" do
      amounts =
        1_000_003 |> then(&TournamentPayout.compute(grid(), 50, 50, &1)) |> Enum.map(& &1.amount)

      assert amounts == Enum.sort(amounts, :desc)
    end

    test "нулевой фонд не порождает отрицательных выплат" do
      payouts = TournamentPayout.compute(grid(), 50, 50, 0)

      assert Enum.all?(payouts, &(&1.amount == 0))
      assert TournamentPayout.total(payouts) == 0
    end
  end

  describe "усечение мест по числу живых людей" do
    test "мест не больше, чем уникальных участников" do
      # 70 входов дали всего двух живых людей: сетка на четыре места
      # физически неисполнима.
      payouts = TournamentPayout.compute(grid(), 70, 2, 1000)

      assert length(payouts) == 2
      assert Enum.map(payouts, & &1.place) == [1, 2]
    end

    test "после усечения фонд по-прежнему раздаётся целиком" do
      payouts = TournamentPayout.compute(grid(), 70, 2, 1000)

      assert TournamentPayout.total(payouts) == 1000
    end

    test "доли усечённых мест расходятся пропорционально" do
      payouts = TournamentPayout.compute(grid(), 70, 2, 1000)

      # Было 500k и 300k из миллиона; после усечения — 5/8 и 3/8.
      assert Enum.map(payouts, & &1.amount) == [625, 375]
    end
  end

  describe "билеты и саттелиты" do
    test "билет выдаётся вместо денег, деньги считаются от остатка фонда" do
      grid = [
        ticket(2, nil, 1, 2, "t1", 1000),
        money(2, nil, 3, 3, 1_000_000)
      ]

      payouts = TournamentPayout.compute(grid, 10, 10, 2500)

      assert Enum.map(payouts, & &1.ticket_id) == ["t1", "t1", nil]

      # Два билета по 1000 съели 2000, третьему месту остались 500.
      assert Enum.map(payouts, & &1.amount) == [0, 0, 500]
      assert TournamentPayout.total(payouts) == 2500
    end

    test "билетов больше, чем позволяет фонд: лишние места получают деньги" do
      grid = [ticket(2, nil, 1, 3, "t1", 1000)]

      payouts = TournamentPayout.compute(grid, 10, 10, 2500)

      # Хватило на два билета; третье место получило остаток деньгами.
      assert Enum.map(payouts, & &1.ticket_id) == ["t1", "t1", nil]
      assert Enum.map(payouts, & &1.amount) == [0, 0, 500]
      assert TournamentPayout.total(payouts) == 2500
    end

    test "чистый саттелит: фонд уходит в билеты, остаток — следующему месту" do
      grid = [ticket(2, nil, 1, 5, "t1", 1000)]

      payouts = TournamentPayout.compute(grid, 20, 20, 3300)

      assert Enum.count(payouts, &(&1.ticket_id == "t1")) == 3
      assert TournamentPayout.total(payouts) == 3300
    end
  end

  describe "валидация сетки" do
    test "корректная сетка проходит" do
      assert TournamentPayout.validate(grid(), 2, 1000) == :ok
    end

    test "пустая сетка — турнир нечем закончить" do
      assert TournamentPayout.validate([], 2, 100) == {:error, :no_payouts}
    end

    test "дыра между полосами явки" do
      grid = [money(2, 9, 1, 1, @ppm), money(20, nil, 1, 1, @ppm)]

      assert TournamentPayout.validate(grid, 2, 100) == {:error, :entries_gap}
    end

    test "полосы явки пересекаются" do
      grid = [money(2, 15, 1, 1, @ppm), money(10, nil, 1, 1, @ppm)]

      assert TournamentPayout.validate(grid, 2, 100) == {:error, :entries_overlap}
    end

    test "последняя полоса обязана быть открыта вверх" do
      grid = [money(2, 9, 1, 1, @ppm)]

      assert TournamentPayout.validate(grid, 2, 100) == {:error, :entries_gap}
    end

    test "места внутри полосы идут подряд с первого" do
      grid = [money(2, nil, 2, 3, @ppm)]

      assert TournamentPayout.validate(grid, 2, 100) == {:error, :places_not_contiguous}
    end

    test "доли обязаны складываться ровно в миллион" do
      grid = [money(2, nil, 1, 1, 600_000), money(2, nil, 2, 2, 300_000)]

      assert TournamentPayout.validate(grid, 2, 100) == {:error, :shares_do_not_sum}
    end

    test "первое место не может получить меньше второго" do
      grid = [money(2, nil, 1, 1, 300_000), money(2, nil, 2, 2, 700_000)]

      assert TournamentPayout.validate(grid, 2, 100) == {:error, :shares_increase}
    end

    test "мест не больше, чем входов в полосе" do
      grid = [money(3, nil, 1, 4, 250_000)]

      assert TournamentPayout.validate(grid, 3, 100) == {:error, :too_many_paid_places}
    end

    test "полоса без денежных строк законна — это саттелит" do
      grid = [ticket(2, nil, 1, 2, "t1", 100)]

      assert TournamentPayout.validate(grid, 2, 100) == :ok
    end
  end

  describe "инварианты" do
    property "сумма выплат ровно равна фонду при любой явке и любом фонде" do
      check all(
              entries <- integer(2..500),
              players <- integer(1..500),
              pool <- integer(0..10_000_000)
            ) do
        payouts = TournamentPayout.compute(grid(), entries, min(players, entries), pool)

        assert TournamentPayout.total(payouts) == pool
      end
    end

    property "число оплаченных мест не превышает ни явку, ни число живых людей" do
      check all(entries <- integer(2..500), players <- integer(1..500)) do
        players = min(players, entries)
        payouts = TournamentPayout.compute(grid(), entries, players, 100_000)

        assert length(payouts) <= players
        assert length(payouts) <= entries
      end
    end

    property "выплата не возрастает с местом" do
      check all(entries <- integer(10..500), pool <- integer(0..1_000_000)) do
        amounts =
          grid()
          |> TournamentPayout.compute(entries, entries, pool)
          |> Enum.map(& &1.amount)

        assert amounts == Enum.sort(amounts, :desc)
      end
    end

    property "места идут подряд с первого и без повторов" do
      check all(entries <- integer(2..500), players <- integer(1..500)) do
        players = min(players, entries)

        places =
          grid()
          |> TournamentPayout.compute(entries, players, 50_000)
          |> Enum.map(& &1.place)

        assert places == Enum.to_list(1..length(places)//1)
      end
    end
  end
end
