defmodule BlockPoker.Engine.DeckTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BlockPoker.Engine.{Deck, Rng, Variant}

  describe "состав колоды" do
    test "колоду задаёт вариант" do
      assert length(Deck.new(Variant.TexasHoldem)) == 52
      assert length(Deck.new(Variant.Artificial)) == 40
    end

    test "карты в колоде не повторяются" do
      deck = Deck.new(Variant.TexasHoldem)
      assert Enum.uniq(deck) == deck
    end
  end

  describe "тасовка" do
    test "перестановка сохраняет состав" do
      deck = Deck.new(Variant.TexasHoldem)
      {shuffled, _rng} = Deck.shuffle(deck, Rng.seeded("состав"))

      assert Enum.sort(shuffled) == deck
    end

    test "один seed — одна раздача" do
      deck = Deck.new(Variant.TexasHoldem)
      {left, _} = Deck.shuffle(deck, Rng.seeded("seed"))
      {right, _} = Deck.shuffle(deck, Rng.seeded("seed"))

      assert left == right
    end

    test "разные seed дают разный порядок" do
      deck = Deck.new(Variant.TexasHoldem)
      {left, _} = Deck.shuffle(deck, Rng.seeded("первый"))
      {right, _} = Deck.shuffle(deck, Rng.seeded("второй"))

      refute left == right
    end

    test "тасовка вообще меняет порядок" do
      deck = Deck.new(Variant.TexasHoldem)
      {shuffled, _} = Deck.shuffle(deck, Rng.seeded("порядок"))

      refute shuffled == deck
    end

    test "боевой RNG тоже тасует" do
      deck = Deck.new(Variant.TexasHoldem)
      {shuffled, _} = Deck.shuffle(deck, Rng.default())

      assert Enum.sort(shuffled) == deck
    end
  end

  describe "RNG" do
    test "числа не выходят за границу" do
      {values, _rng} =
        Enum.map_reduce(1..500, Rng.seeded("границы"), fn _index, rng ->
          Rng.uniform_below(rng, 52)
        end)

      assert Enum.all?(values, &(&1 in 0..51))
    end

    test "распределение не вырождено" do
      {values, _rng} =
        Enum.map_reduce(1..2_000, Rng.seeded("распределение"), fn _index, rng ->
          Rng.uniform_below(rng, 6)
        end)

      assert values |> Enum.uniq() |> Enum.sort() == [0, 1, 2, 3, 4, 5]
    end

    test "дочерние RNG независимы и воспроизводимы" do
      {[first, second], _} = Rng.split(Rng.seeded("ветвление"), 2)
      {[repeat, _], _} = Rng.split(Rng.seeded("ветвление"), 2)

      deck = Deck.new(Variant.TexasHoldem)
      {left, _} = Deck.shuffle(deck, first)
      {right, _} = Deck.shuffle(deck, second)
      {again, _} = Deck.shuffle(deck, repeat)

      refute left == right
      assert left == again
    end
  end

  property "тасовка любого набора карт — перестановка" do
    check all(cards <- StreamData.uniq_list_of(StreamData.integer(0..51), max_length: 20)) do
      {shuffled, _rng} = Deck.shuffle(cards, Rng.seeded(cards))
      assert Enum.sort(shuffled) == Enum.sort(cards)
    end
  end
end
