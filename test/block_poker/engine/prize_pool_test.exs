defmodule BlockPoker.Engine.PrizePoolTest do
  @moduledoc """
  Лотерейный призовой фонд: розыгрыш тира и раскладка по местам.

  Главное, что здесь проверяется, — деньги. Раскладка обязана сходиться
  с фондом ровно, а распределение розыгрыша — соответствовать заявленным
  шансам: и то и другое ошибается молча, если не смотреть.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BlockPoker.Engine.{PrizePool, Rng}

  defp tier(multiplier, chance, payouts \\ [100]),
    do: %{multiplier: multiplier, chance_ppm: chance, payouts: payouts}

  describe "prize_pool/2" do
    test "приз считается от взноса, а не от суммы взносов" do
      # x2 при взносе $1: фонд $2 — при трёх внесённых долларах.
      assert PrizePool.prize_pool(100, 200) == 200
      assert PrizePool.prize_pool(25, 200) == 50
      assert PrizePool.prize_pool(10_000, 1_000_000) == 100_000_000
    end

    test "дробный результат округляется вниз: фонд обязан быть целым" do
      # x2.5 от 25 центов — 62.5, в фонд уходит 62.
      assert PrizePool.prize_pool(25, 250) == 62
    end
  end

  describe "split/2" do
    test "победитель забирает весь фонд" do
      assert PrizePool.split(600, [100]) == [600]
    end

    test "сумма выплат равна фонду ровно" do
      assert PrizePool.split(1000, [75, 20, 5]) == [750, 200, 50]
    end

    test "остаток от округления достаётся первому месту" do
      # 65% и 35% от 101 дают 65 и 35 — одна единица потерялась бы.
      assert PrizePool.split(101, [65, 35]) == [66, 35]
      assert PrizePool.split(101, [65, 35]) |> Enum.sum() == 101
    end

    test "нулевой фонд раскладывается в нули, а не падает" do
      assert PrizePool.split(0, [75, 20, 5]) == [0, 0, 0]
    end

    property "выплаты всегда складываются в фонд" do
      check all(
              pool <- integer(0..10_000_000),
              payouts <- member_of([[100], [80, 20], [65, 35], [75, 20, 5], [50, 25, 15, 10]])
            ) do
        shares = PrizePool.split(pool, payouts)

        assert Enum.sum(shares) == pool
        assert Enum.all?(shares, &(&1 >= 0))
      end
    end
  end

  describe "draw/2" do
    test "тир с полным шансом выпадает всегда" do
      {drawn, _rng} = PrizePool.draw(Rng.seeded("seed"), [tier(200, 1_000_000)])

      assert drawn.multiplier == 200
    end

    test "розыгрыш воспроизводим по seed" do
      table = [tier(200, 700_000), tier(400, 299_000), tier(10_000, 1_000)]

      draws =
        for seed <- 1..50 do
          {tier, _rng} = PrizePool.draw(Rng.seeded(seed), table)
          tier.multiplier
        end

      repeat =
        for seed <- 1..50 do
          {tier, _rng} = PrizePool.draw(Rng.seeded(seed), table)
          tier.multiplier
        end

      assert draws == repeat
    end

    test "таблица с суммой шансов не в полную шкалу — ошибка конфигурации" do
      assert_raise ArgumentError, fn ->
        PrizePool.draw(Rng.seeded("seed"), [tier(200, 999_999)])
      end
    end

    test "пустая таблица — ошибка конфигурации" do
      assert_raise ArgumentError, fn -> PrizePool.draw(Rng.seeded("seed"), []) end
    end

    test "частоты сходятся с заявленными шансами" do
      table = [tier(200, 750_000), tier(400, 200_000), tier(1_000, 50_000)]

      counts =
        Enum.reduce(1..20_000, {%{}, Rng.seeded("frequency")}, fn _index, {acc, rng} ->
          {tier, rng} = PrizePool.draw(rng, table)
          {Map.update(acc, tier.multiplier, 1, &(&1 + 1)), rng}
        end)
        |> elem(0)

      # Допуск широкий намеренно: тест ловит перепутанные веса и смещение
      # генератора, а не проверяет статистику с точностью до процента.
      assert_in_delta counts[200] / 20_000, 0.75, 0.02
      assert_in_delta counts[400] / 20_000, 0.20, 0.02
      assert_in_delta counts[1_000] / 20_000, 0.05, 0.02
    end
  end

  describe "expected_return_ppm/2" do
    test "возврат игроку — это матожидание множителя, делённое на число мест" do
      # Вырожденная таблица: всегда x3 за столом на троих — возврат ровно 100%.
      table = [tier(300, 1_000_000)]

      assert PrizePool.expected_return_ppm(table, 3) == 1_000_000
    end

    test "тот же набор тиров за столом на шестерых возвращает вдвое меньше" do
      table = [tier(300, 1_000_000)]

      assert PrizePool.expected_return_ppm(table, 6) == 500_000
    end
  end

  describe "multiplier_label/1" do
    test "целые множители пишутся без дробной части" do
      assert PrizePool.multiplier_label(200) == "X2"
      assert PrizePool.multiplier_label(1_000_000) == "X10000"
    end

    test "дробные множители сохраняют значащие разряды" do
      assert PrizePool.multiplier_label(250) == "X2.5"
      assert PrizePool.multiplier_label(205) == "X2.05"
    end
  end
end
