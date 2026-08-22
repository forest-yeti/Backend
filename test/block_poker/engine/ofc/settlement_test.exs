defmodule BlockPoker.Engine.Ofc.SettlementTest do
  @moduledoc """
  Перевод очков в фишки: ограничение по стеку должника и сохранение фишек.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BlockPoker.Engine.Ofc.Settlement

  defp scores(pairs) do
    Map.new(pairs, fn {seat, against} -> {seat, %{against: against}} end)
  end

  test "стека хватает — переносы идут полностью" do
    result =
      Settlement.settle(
        scores(%{1 => %{2 => 5}, 2 => %{1 => -5}}),
        %{1 => 100, 2 => 100},
        10
      )

    assert result.deltas == %{1 => 50, 2 => -50}
    assert result.transfers == [%{from: 2, to: 1, amount: 50}]
  end

  test "стека не хватает — платится ровно стек, и ни фишкой больше" do
    result =
      Settlement.settle(
        scores(%{1 => %{2 => 5}, 2 => %{1 => -5}}),
        %{1 => 100, 2 => 10},
        10
      )

    assert result.deltas == %{1 => 10, 2 => -10}
  end

  test "двое кредиторов делят нехватку пропорционально долгу" do
    # Место 1 должно 30 очков месту 2 и 20 месту 3, но на стеке 10 фишек.
    result =
      Settlement.settle(
        scores(%{
          1 => %{2 => -30, 3 => -20},
          2 => %{1 => 30, 3 => 0},
          3 => %{1 => 20, 2 => 0}
        }),
        %{1 => 10, 2 => 500, 3 => 500},
        1
      )

    assert result.deltas == %{1 => -10, 2 => 6, 3 => 4}
  end

  test "остаток целочисленного деления уходит по возрастанию номера места" do
    result =
      Settlement.settle(
        scores(%{
          1 => %{2 => -1, 3 => -1},
          2 => %{1 => 1, 3 => 0},
          3 => %{1 => 1, 2 => 0}
        }),
        %{1 => 1, 2 => 500, 3 => 500},
        1
      )

    assert result.deltas == %{1 => -1, 2 => 1, 3 => 0}
  end

  property "фишки не возникают и не исчезают, и ни один стек не уходит в минус" do
    check all(
            points <- integer(-40..40),
            other <- integer(-40..40),
            stacks <- list_of(integer(0..200), length: 3),
            point_value <- integer(1..50)
          ) do
      [first, second, third] = stacks
      stacks = %{1 => first, 2 => second, 3 => third}

      # Третье ребро выводится из первых двух: сумма очков места по всем
      # соперникам и есть его итог, а сумма итогов обязана быть нулём.
      against =
        scores(%{
          1 => %{2 => points, 3 => other},
          2 => %{1 => -points, 3 => -(points + other)},
          3 => %{1 => -other, 2 => points + other}
        })

      result = Settlement.settle(against, stacks, point_value)

      assert result.deltas |> Map.values() |> Enum.sum() == 0

      Enum.each(stacks, fn {seat, stack} ->
        assert stack + result.deltas[seat] >= 0
      end)
    end
  end
end
