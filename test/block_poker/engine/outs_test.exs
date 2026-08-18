defmodule BlockPoker.Engine.OutsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BlockPoker.Engine.{Card, Equity, Outs, Showdown, Variant}

  @holdem Variant.TexasHoldem

  defp hand(string), do: Card.parse_many!(string)

  describe "подсчёт аутов" do
    test "у отстающего с двумя оверкартами — шесть аутов" do
      hands = [{:alice, hand("QS QD")}, {:bob, hand("AH KS")}]
      outs = Outs.compute(hands, hand("2C 7D 9S"), @holdem)

      assert outs[:alice] == []
      assert Enum.map(outs[:bob], &{&1.rank, &1.count}) == [{14, 3}, {13, 3}]
    end

    test "у лидера аутов нет" do
      hands = [{:alice, hand("AS AD")}, {:bob, hand("KS KD")}]
      outs = Outs.compute(hands, hand("2C 7H 9S"), @holdem)

      assert outs[:alice] == []
      assert Enum.map(outs[:bob], & &1.rank) == [13]
    end

    test "флеш-дро — девять аутов одной масти" do
      hands = [{:alice, hand("9S 9D")}, {:bob, hand("AH KH")}]
      outs = Outs.compute(hands, hand("2H 7H TC"), @holdem)

      hearts = Enum.flat_map(outs[:bob], & &1.cards)

      assert Enum.count(hearts, &(Card.suit(&1) == Card.suit(Card.parse!("2H")))) == 9
    end

    test "аут засчитывается и тогда, когда даёт сплит" do
      # Борду не хватает одной карты до стрита, который сыграет у обоих.
      hands = [{:alice, hand("AS KS")}, {:bob, hand("2C 3D")}]
      outs = Outs.compute(hands, hand("7H 8D 9S TC"), @holdem)

      sixes = Enum.find(outs[:bob], &(&1.rank == 6))

      assert sixes.count == 4
      assert Enum.all?(sixes.cards, &(Card.rank(&1) == 4))
    end

    test "на ривере аутов нет ни у кого" do
      hands = [{:alice, hand("AS AD")}, {:bob, hand("KS KD")}]

      assert Outs.compute(hands, hand("2C 7H 9S TD 3C"), @holdem) == %{alice: [], bob: []}
    end

    test "против неизвестной руки ауты не считаются" do
      hands = [{:alice, hand("AS AD")}, {:bob, :unknown}]

      assert Outs.compute(hands, hand("2C 7H 9S"), @holdem) == %{alice: []}
    end

    test "мёртвые карты вычитаются из аутов" do
      hands = [{:alice, hand("AS AD")}, {:bob, hand("KS KD")}]
      outs = Outs.compute(hands, hand("2C 7H 9S TD"), @holdem, hand("KH"))

      assert Enum.map(outs[:bob], &{&1.rank, &1.count}) == [{13, 1}]
    end

    test "ауты приезжают вместе с эквити" do
      result =
        Equity.equity(
          [{:alice, hand("AS AD")}, {:bob, hand("KS KD")}],
          hand("2C 7H 9S TD"),
          @holdem
        )

      bob = Enum.find(result.players, &(&1.id == :bob))

      assert Enum.map(bob.outs, &{&1.rank, &1.count}) == [{13, 2}]
    end

    test "ауты можно не считать" do
      result =
        Equity.equity(
          [{:alice, hand("AS AD")}, {:bob, hand("KS KD")}],
          hand("2C 7H 9S TD"),
          @holdem,
          outs: false
        )

      assert Enum.all?(result.players, &(&1.outs == []))
    end
  end

  property "каждый аут действительно выводит в лидеры" do
    check all(
            cards <- StreamData.uniq_list_of(StreamData.integer(0..51), length: 8),
            max_runs: 30
          ) do
      [a, b, c, d | board] = cards
      hands = [{:alice, [a, b]}, {:bob, [c, d]}]
      outs = Outs.compute(hands, board, @holdem)

      for {id, player_outs} <- outs, out <- player_outs, card <- out.cards do
        # Проверяется прямым прогоном вскрытия, а не повтором той же формулы.
        assert id in Showdown.winners(hands, [card | board], @holdem)
      end
    end
  end

  property "у лидера аутов не бывает" do
    check all(
            cards <- StreamData.uniq_list_of(StreamData.integer(0..51), length: 8),
            max_runs: 30
          ) do
      [a, b, c, d | board] = cards
      hands = [{:alice, [a, b]}, {:bob, [c, d]}]
      leaders = Showdown.winners(hands, board, @holdem)
      outs = Outs.compute(hands, board, @holdem)

      assert Enum.all?(leaders, &(outs[&1] == []))
    end
  end

  property "count всегда равен длине списка карт" do
    check all(
            cards <- StreamData.uniq_list_of(StreamData.integer(0..51), length: 8),
            max_runs: 20
          ) do
      [a, b, c, d | board] = cards
      outs = Outs.compute([{:alice, [a, b]}, {:bob, [c, d]}], board, @holdem)

      for {_id, player_outs} <- outs, out <- player_outs do
        assert out.count == length(out.cards)
        assert Enum.all?(out.cards, &(Card.rank(&1) + 2 == out.rank))
      end
    end
  end
end
