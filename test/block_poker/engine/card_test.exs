defmodule BlockPoker.Engine.CardTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BlockPoker.Engine.Card

  describe "внутреннее представление" do
    test "карта раскладывается на ранг и масть" do
      assert Card.rank(Card.new(12, 0)) == 12
      assert Card.suit(Card.new(12, 3)) == 3
    end

    test "все 52 карты различны" do
      assert 0..51 |> Enum.map(&{Card.rank(&1), Card.suit(&1)}) |> Enum.uniq() |> length() == 52
    end
  end

  describe "внешнее представление" do
    test "туз пик уходит наружу как rank 14" do
      assert Card.to_map(Card.parse!("AS")) == %{rank: 14, suit: "S"}
    end

    test "двойка — младшая карта внешней шкалы" do
      assert Card.to_map(Card.parse!("2C")) == %{rank: 2, suit: "C"}
    end

    test "разбор принимает строковые и атомные ключи" do
      assert Card.from_map(%{"rank" => 11, "suit" => "H"}) == {:ok, Card.parse!("JH")}
      assert Card.from_map(%{rank: 11, suit: "H"}) == {:ok, Card.parse!("JH")}
    end

    test "внутренняя шкала 0..12 наружу не протекает" do
      refute Enum.any?(0..51, fn card -> Card.to_map(card).rank < 2 end)
    end

    test "некорректные карты отвергаются" do
      assert Card.from_map(%{rank: 1, suit: "S"}) == {:error, :invalid_card}
      assert Card.from_map(%{rank: 15, suit: "S"}) == {:error, :invalid_card}
      assert Card.from_map(%{rank: 10, suit: "X"}) == {:error, :invalid_card}
      assert Card.from_map(%{rank: 10}) == {:error, :invalid_card}
      assert Card.from_map("AS") == {:error, :invalid_card}
    end

    test "список карт валится целиком, если испорчена одна карта" do
      assert Card.from_list([%{rank: 14, suit: "S"}, %{rank: 1, suit: "S"}]) ==
               {:error, :invalid_card}
    end
  end

  property "разбор и вывод — взаимно обратные операции" do
    check all(card <- StreamData.integer(0..51)) do
      assert {:ok, ^card} = card |> Card.to_map() |> Card.from_map()
    end
  end

  property "короткая запись читается обратно" do
    check all(card <- StreamData.integer(0..51)) do
      assert Card.parse!(Card.to_string(card)) == card
    end
  end
end
