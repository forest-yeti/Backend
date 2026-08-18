defmodule BlockPoker.Engine.ButtonDrawTest do
  @moduledoc """
  Розыгрыш кнопки — правило игры, поэтому тесты уровня 1: без БД,
  без процессов, с инжектируемым RNG.
  """

  use ExUnit.Case, async: true

  alias BlockPoker.Engine.{ButtonDraw, Card, Rng}
  alias BlockPoker.Engine.Variant.TexasHoldem

  @seats [1, 3, 5, 7]

  describe "draw/3" do
    test "каждому месту достаётся ровно одна карта, все карты разные" do
      {_button, drawn, _rng} = ButtonDraw.draw(@seats, TexasHoldem, Rng.seeded("button"))

      assert Enum.map(drawn, & &1.seat) == @seats
      assert drawn |> Enum.map(& &1.card) |> Enum.uniq() |> length() == length(@seats)
    end

    test "кнопку получает старшая карта" do
      {button, drawn, _rng} = ButtonDraw.draw(@seats, TexasHoldem, Rng.seeded("button"))

      best = Enum.max_by(drawn, &Card.rank(&1.card))
      assert Card.rank(Enum.find(drawn, &(&1.seat == button)).card) == Card.rank(best.card)
    end

    test "с фиксированным seed результат воспроизводим" do
      first = ButtonDraw.draw(@seats, TexasHoldem, Rng.seeded("fixed"))
      second = ButtonDraw.draw(@seats, TexasHoldem, Rng.seeded("fixed"))

      assert elem(first, 0) == elem(second, 0)
      assert elem(first, 1) == elem(second, 1)
    end

    test "розыгрыш продвигает RNG: следующая раздача не повторит колоду" do
      rng = Rng.seeded("fixed")
      {_button, _drawn, advanced} = ButtonDraw.draw(@seats, TexasHoldem, rng)

      assert advanced != rng
    end
  end

  describe "winner/1 — тайбрейк" do
    test "при равных рангах решает масть: пики старше червей" do
      drawn = [
        %{seat: 1, card: Card.parse!("KH")},
        %{seat: 2, card: Card.parse!("KS")},
        %{seat: 3, card: Card.parse!("KD")}
      ]

      assert ButtonDraw.winner(drawn) == 2
    end

    test "ранг важнее масти: трефовый туз бьёт пиковую даму" do
      drawn = [
        %{seat: 1, card: Card.parse!("QS")},
        %{seat: 2, card: Card.parse!("AC")}
      ]

      assert ButtonDraw.winner(drawn) == 2
    end

    test "порядок мастей — пики, черви, бубны, трефы" do
      by_suit =
        Enum.map(["AS", "AH", "AD", "AC"], fn short ->
          %{seat: 1, card: Card.parse!(short)}
        end)

      # Каждая следующая масть слабее предыдущей, поэтому победителем любой
      # пары остаётся та, что раньше в списке.
      for {stronger, index} <- Enum.with_index(by_suit),
          weaker <- Enum.drop(by_suit, index + 1) do
        assert ButtonDraw.winner([%{stronger | seat: 1}, %{weaker | seat: 2}]) == 1
      end
    end
  end
end
