defmodule BlockPoker.Engine.ShortDeckTest do
  @moduledoc """
  Short Deck: колода, роспись комбинаций и стриты.

  Про ставки — `BlockPoker.Engine.ButtonAnteTest`: колода и структура
  независимы, и проверяются они порознь.
  """

  use ExUnit.Case, async: true

  alias BlockPoker.Engine.BettingStructure
  alias BlockPoker.Engine.{Card, Deck, HandRank, Rng}
  alias BlockPoker.Engine.Variant.{Registry, ShortDeck}

  defp cards(list) do
    Enum.map(list, fn text ->
      {:ok, card} = Card.parse(text)
      card
    end)
  end

  defp rank(list), do: HandRank.best_of_five(cards(list), ShortDeck)

  describe "колода" do
    test "36 карт: от шестёрки до туза" do
      deck = Deck.new(ShortDeck)

      assert length(deck) == 36
      assert deck |> Enum.map(&Card.rank/1) |> Enum.uniq() |> Enum.sort() == Enum.to_list(4..12)
    end

    test "младших карт нет ни в одной тасовке" do
      # Раздача берёт карты из головы колоды, поэтому важно не «нет в списке»,
      # а «не появляется ни при каком порядке».
      Enum.reduce(1..200, Rng.seeded(<<9::256>>), fn _iteration, rng ->
        {deck, rng} = ShortDeck |> Deck.new() |> Deck.shuffle(rng)

        assert Enum.all?(deck, &(Card.rank(&1) >= 4))
        assert length(Enum.uniq(deck)) == 36

        rng
      end)
    end
  end

  describe "роспись комбинаций" do
    test "флеш бьёт фулл-хаус" do
      flush = rank(~w(AS QS 9S 8S 6S))
      full_house = rank(~w(KS KH KD 7S 7H))

      assert HandRank.compare(flush, full_house) == :gt
      assert flush.category == :flush
      assert full_house.category == :full_house
    end

    test "фулл-хаус по-прежнему бьёт стрит, а стрит — сет" do
      full_house = rank(~w(KS KH KD 7S 7H))
      straight = rank(~w(TS 9H 8D 7S 6H))
      trips = rank(~w(QS QH QD 8S 6H))

      assert HandRank.compare(full_house, straight) == :gt
      assert HandRank.compare(straight, trips) == :gt
    end

    test "каре и стрит-флеш остаются на своих местах" do
      quads = rank(~w(9S 9H 9D 9C 6H))
      flush = rank(~w(AS QS 9S 8S 6S))
      straight_flush = rank(~w(TS 9S 8S 7S 6S))

      assert HandRank.compare(quads, flush) == :gt
      assert HandRank.compare(straight_flush, quads) == :gt
    end
  end

  describe "стриты" do
    test "A6789 — стрит, и сравнивается он по девятке" do
      wheel = rank(~w(AS 9H 8D 7S 6H))
      higher = rank(~w(TS 9H 8D 7S 6C))

      assert wheel.category == :straight
      assert HandRank.compare(higher, wheel) == :gt
    end

    test "туз играет и старшим" do
      broadway = rank(~w(AS KH QD JS TH))

      assert broadway.category == :straight
      assert HandRank.compare(broadway, rank(~w(AS 9H 8D 7S 6H))) == :gt
    end

    test "A6789 бьёт старшую карту, но проигрывает любому старшему стриту" do
      wheel = rank(~w(AS 9H 8D 7S 6H))

      assert HandRank.compare(wheel, rank(~w(AS KH QD JS 9H))) == :gt
      assert HandRank.compare(wheel, rank(~w(JS TH 9D 8S 7H))) == :lt
    end
  end

  describe "связка с остальным ядром" do
    test "вариант отдаёт структуру ставок, а не блайнды" do
      assert ShortDeck.betting_structure() == BettingStructure.ButtonAnte
    end

    test "вариант доступен по идентификатору из конфигурации стола" do
      assert {:ok, ShortDeck} = Registry.fetch("short_deck")
      assert :short_deck in Registry.ids()
    end
  end
end
