defmodule BlockPoker.Engine.BountyTest do
  @moduledoc """
  Головы баунти-турнира.

  Главный тест — property на инвариант:

      Σ выплат + Σ возвратов + Σ голов живых = входы × bounty_part

  Он ловит сразу три ошибки, которые иначе обнаружились бы только на
  живом турнире: потерянный остаток от деления, двойную выплату и
  невыплаченную голову победителя.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BlockPoker.Engine.Bounty

  @pko %{progressive?: true, split_ppm: 500_000}
  @fixed %{progressive?: false, split_ppm: 500_000}
  @table %{button_seat: 1, table_size: 6}

  defp victim(id, bounty, killers, opts \\ []) do
    %{
      entry_id: id,
      seat: Keyword.get(opts, :seat, 3),
      bounty: bounty,
      stack_before: Keyword.get(opts, :stack_before, 100),
      killers: killers
    }
  end

  defp killer(id, seat), do: %{entry_id: id, seat: seat}

  describe "деление взноса" do
    test "призовая часть — это взнос за вычетом головы" do
      assert Bounty.prize_part(1000, 400) == 600
    end

    test "не баунти-турнир: весь взнос в фонд" do
      assert Bounty.prize_part(1000, 0) == 1000
    end

    test "стартовая голова равна цене головы шаблона" do
      assert Bounty.initial(400) == 400
    end
  end

  describe "PKO: один убийца" do
    test "половина деньгами, половина на голову убийцы" do
      result = Bounty.settle([victim(:v, 400, [killer(:a, 5)])], @pko, @table)

      assert [%{entry_id: :a, victim_entry_id: :v, amount: 200}] = result.payouts
      assert [%{entry_id: :a, amount: 200}] = result.increments
      assert result.refunds == []
    end

    test "нечётная голова: остаток уходит на голову, а не в карман" do
      result = Bounty.settle([victim(:v, 401, [killer(:a, 5)])], @pko, @table)

      assert [%{amount: 200}] = result.payouts
      assert [%{amount: 201}] = result.increments
    end

    test "другая доля деления работает тем же кодом" do
      rules = %{progressive?: true, split_ppm: 250_000}
      result = Bounty.settle([victim(:v, 400, [killer(:a, 5)])], rules, @table)

      assert [%{amount: 100}] = result.payouts
      assert [%{amount: 300}] = result.increments
    end
  end

  describe "фиксированный баунти" do
    test "вся голова деньгами, голова убийцы не растёт" do
      result = Bounty.settle([victim(:v, 400, [killer(:a, 5)])], @fixed, @table)

      assert [%{amount: 400}] = result.payouts
      assert result.increments == []
    end
  end

  describe "сплит-пот" do
    test "голова делится поровну между победителями банка" do
      victim = victim(:v, 400, [killer(:a, 5), killer(:b, 3)])
      result = Bounty.settle([victim], @pko, @table)

      assert Enum.map(result.payouts, & &1.amount) == [100, 100]
      assert Enum.map(result.increments, & &1.amount) == [100, 100]
    end

    test "нечётные единицы уходят ближайшему к кнопке по часовой стрелке" do
      # Кнопка на месте 1: место 3 ближе к ней, чем место 5.
      victim = victim(:v, 402, [killer(:far, 5), killer(:near, 3)])
      result = Bounty.settle([victim], @pko, @table)

      near = Enum.find(result.payouts, &(&1.entry_id == :near))
      far = Enum.find(result.payouts, &(&1.entry_id == :far))

      assert near.amount == 101
      assert far.amount == 100
    end

    test "сплит без потери остатка: выплачено ровно столько, сколько стоила голова" do
      victim = victim(:v, 997, [killer(:a, 5), killer(:b, 3), killer(:c, 2)])
      result = Bounty.settle([victim], @pko, @table)

      paid = Enum.sum(Enum.map(result.payouts, & &1.amount))
      grown = Enum.sum(Enum.map(result.increments, & &1.amount))

      assert paid + grown == 997
    end
  end

  describe "несколько выбитых одной раздачей" do
    test "каждая голова считается по своему банку, убийцы могут быть разными" do
      victims = [
        victim(:v1, 400, [killer(:a, 5)], stack_before: 300),
        victim(:v2, 400, [killer(:b, 2)], stack_before: 100)
      ]

      result = Bounty.settle(victims, @pko, @table)

      assert Enum.map(result.payouts, & &1.entry_id) == [:a, :b]
    end

    test "порядок обработки — по стеку на начало раздачи" do
      victims = [
        victim(:small, 400, [killer(:a, 5)], stack_before: 10),
        victim(:big, 400, [killer(:b, 2)], stack_before: 900)
      ]

      result = Bounty.settle(victims, @pko, @table)

      assert Enum.map(result.payouts, & &1.victim_entry_id) == [:big, :small]
    end

    test "один выживший забирает обе головы" do
      victims = [
        victim(:v1, 400, [killer(:a, 5)], stack_before: 300),
        victim(:v2, 200, [killer(:a, 5)], stack_before: 100)
      ]

      result = Bounty.settle(victims, @pko, @table)

      assert Enum.map(result.payouts, & &1.entry_id) == [:a, :a]
      assert Enum.sum(Enum.map(result.payouts, & &1.amount)) == 300
    end
  end

  describe "вылет не в раздаче" do
    test "голова не достаётся никому и возвращается владельцу" do
      result = Bounty.settle([victim(:v, 400, [])], @pko, @table)

      assert result.payouts == []
      assert result.increments == []
      assert [%{entry_id: :v, amount: 400}] = result.refunds
    end
  end

  describe "не баунти-турнир" do
    test "нулевая голова не порождает ни выплат, ни возвратов" do
      result = Bounty.settle([victim(:v, 0, [killer(:a, 5)])], @pko, @table)

      assert result == %{payouts: [], increments: [], refunds: []}
    end
  end

  describe "голова победителя" do
    test "победитель забирает собственную голову деньгами" do
      assert Bounty.winner_payout(:winner, 800) == [%{entry_id: :winner, amount: 800}]
    end

    test "нулевая голова выплаты не порождает" do
      assert Bounty.winner_payout(:winner, 0) == []
    end
  end

  describe "инварианты" do
    # Голова целиком расходится на три части и никуда больше: деньги
    # убийце, прирост его головы, возврат владельцу.
    property "выплаты плюс приросты плюс возвраты равны сумме голов выбитых" do
      check all(
              bounties <- list_of(integer(0..100_000), min_length: 1, max_length: 8),
              killer_count <- integer(1..4),
              split_ppm <- integer(0..1_000_000),
              progressive? <- boolean()
            ) do
        killers = Enum.map(1..killer_count, &killer({:k, &1}, &1))

        victims =
          bounties
          |> Enum.with_index()
          |> Enum.map(fn {bounty, index} ->
            victim({:v, index}, bounty, killers, stack_before: index * 10)
          end)

        result =
          Bounty.settle(victims, %{progressive?: progressive?, split_ppm: split_ppm}, @table)

        total = fn list -> Enum.reduce(list, 0, &(&2 + &1.amount)) end

        assert total.(result.payouts) + total.(result.increments) + total.(result.refunds) ==
                 Enum.sum(bounties)
      end
    end

    property "ни одна голова не выплачена дважды одному убийце" do
      check all(
              bounty <- integer(1..100_000),
              killer_count <- integer(1..5)
            ) do
        killers = Enum.map(1..killer_count, &killer({:k, &1}, &1))
        result = Bounty.settle([victim(:v, bounty, killers)], @pko, @table)

        pairs = Enum.map(result.payouts, &{&1.victim_entry_id, &1.entry_id})

        assert pairs == Enum.uniq(pairs)
      end
    end

    property "выплаты никогда не отрицательны" do
      check all(
              bounty <- integer(0..100_000),
              split_ppm <- integer(0..1_000_000)
            ) do
        result =
          Bounty.settle(
            [victim(:v, bounty, [killer(:a, 2), killer(:b, 4)])],
            %{progressive?: true, split_ppm: split_ppm},
            @table
          )

        assert Enum.all?(result.payouts, &(&1.amount > 0))
        assert Enum.all?(result.increments, &(&1.amount > 0))
      end
    end

    property "фиксированный баунти отдаёт голову целиком деньгами" do
      check all(bounty <- integer(1..100_000)) do
        result = Bounty.settle([victim(:v, bounty, [killer(:a, 2)])], @fixed, @table)

        assert Enum.reduce(result.payouts, 0, &(&2 + &1.amount)) == bounty
        assert result.increments == []
      end
    end
  end
end
