defmodule BlockPoker.Engine.HandRankTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BlockPoker.Engine.{Card, Combinatorics, HandRank, Variant}

  @holdem Variant.TexasHoldem

  defp hand(string), do: Card.parse_many!(string)
  defp rank(string), do: HandRank.best_of_five(hand(string), @holdem)
  defp score(string), do: rank(string).score

  describe "категории" do
    test "каждая категория распознаётся" do
      assert rank("AS KS QS JS TS").category == :straight_flush
      assert rank("9H 9D 9C 9S 2H").category == :four_of_a_kind
      assert rank("9H 9D 9C 2S 2H").category == :full_house
      assert rank("AH 9H 5H 3H 2H").category == :flush
      assert rank("9H 8D 7C 6S 5H").category == :straight
      assert rank("9H 9D 9C 4S 2H").category == :three_of_a_kind
      assert rank("9H 9D 4C 4S 2H").category == :two_pair
      assert rank("9H 9D 7C 4S 2H").category == :pair
      assert rank("AH 9D 7C 4S 2H").category == :high_card
    end

    test "стрит от туза вниз — младший стрит, а не старший" do
      wheel = rank("AS 2H 3D 4C 5S")

      assert wheel.category == :straight
      assert wheel.score < score("6S 5H 4D 3C 2H")
      assert wheel.score > score("AS KH QD JC 9S")
    end

    test "в стрите от туза вниз туз замыкает комбинацию" do
      assert Enum.map(rank("AS 2H 3D 4C 5S").cards, &Card.to_map(&1).rank) == [5, 4, 3, 2, 14]
    end

    test "туз в стрите не считается одновременно верхом и низом" do
      assert rank("AS KH QD 2C 3S").category == :high_card
    end

    test "стрит-флеш от туза вниз остаётся стрит-флешем" do
      assert rank("AS 2S 3S 4S 5S").category == :straight_flush
    end
  end

  describe "порядок силы" do
    test "эталонный набор рук упорядочен от младшей к старшей" do
      hands = [
        "AH 9D 7C 4S 2H",
        "2H 2D 7C 4S 3H",
        "9H 9D 7C 4S 2H",
        "9H 9D 4C 4S 2H",
        "AH AD 4C 4S 2H",
        "9H 9D 9C 4S 2H",
        "9H 8D 7C 6S 5H",
        "AH 9H 5H 3H 2H",
        "9H 9D 9C 2S 2H",
        "9H 9D 9C 9S 2H",
        "9H 8H 7H 6H 5H"
      ]

      scores = Enum.map(hands, &score/1)
      assert scores == Enum.sort(scores)
      assert Enum.uniq(scores) == scores
    end

    test "две пары слабее сета" do
      assert score("KH KD 4C 4S 2H") < score("2H 2D 2C KS 4H")
    end

    test "кикер решает при равной паре" do
      assert score("9H 9D AC 4S 2H") > score("9S 9C KC 4H 2D")
    end

    test "полностью одинаковые по силе руки дают равный score" do
      assert score("9H 9D AC 4S 2H") == score("9S 9C AD 4H 2S")
    end

    test "старший флеш бьёт младший" do
      assert score("AH 9H 5H 3H 2H") > score("KH 9H 5H 3H 2H")
    end
  end

  describe "best_hand" do
    test "выбирает лучшую пятёрку из семи карт" do
      best = HandRank.best_hand(hand("AS KS QS JS TS 2H 3D"), @holdem)

      assert best.category == :straight_flush
      assert Enum.sort(best.cards) == Enum.sort(hand("AS KS QS JS TS"))
    end

    test "из семи карт с двумя парами и сетом собирает фулл-хаус" do
      assert HandRank.best_hand(hand("AS AH KD KC KS 2H 9D"), @holdem).category == :full_house
    end

    test "меньше пяти карт оценить нечем" do
      assert HandRank.best_hand(hand("AS KS"), @holdem) == nil
    end
  end

  describe "сравнение" do
    test "compare отдаёт направление, а не число" do
      assert HandRank.compare(rank("AS AH KD 4C 2S"), rank("KS KH QD 4C 2S")) == :gt
      assert HandRank.compare(rank("KS KH QD 4C 2S"), rank("AS AH KD 4C 2S")) == :lt
      assert HandRank.compare(rank("AS AH KD 4C 2S"), rank("AD AC KS 4H 2D")) == :eq
    end
  end

  describe "вариант задаёт порядок категорий" do
    test "в искусственном варианте флеш сильнее фулл-хауса" do
      flush = HandRank.best_of_five(hand("AH TH 8H 6H 5H"), Variant.Artificial)
      full_house = HandRank.best_of_five(hand("9H 9D 9C 8S 8H"), Variant.Artificial)

      assert flush.score > full_house.score

      holdem_flush = HandRank.best_of_five(hand("AH TH 8H 6H 5H"), @holdem)
      holdem_full_house = HandRank.best_of_five(hand("9H 9D 9C 8S 8H"), @holdem)

      assert holdem_flush.score < holdem_full_house.score
    end

    test "искусственный вариант знает свой младший стрит A5678" do
      assert HandRank.best_of_five(hand("AH 5D 6C 7S 8H"), Variant.Artificial).category ==
               :straight

      assert HandRank.best_of_five(hand("AH 5D 6C 7S 8H"), @holdem).category == :high_card
    end
  end

  defp five_cards do
    StreamData.uniq_list_of(StreamData.integer(0..51), length: 5)
  end

  property "оценка не зависит от порядка карт на входе" do
    check all(cards <- five_cards(), shuffled <- shuffled(cards)) do
      assert score_of(cards) == score_of(shuffled)
    end
  end

  property "сравнение тотально и транзитивно" do
    check all(left <- five_cards(), middle <- five_cards(), right <- five_cards()) do
      [a, b, c] = Enum.map([left, middle, right], &HandRank.best_of_five(&1, @holdem))

      assert HandRank.compare(a, b) in [:gt, :eq, :lt]

      if HandRank.compare(a, b) == :gt and HandRank.compare(b, c) == :gt do
        assert HandRank.compare(a, c) == :gt
      end

      if HandRank.compare(a, b) == :eq and HandRank.compare(b, c) == :eq do
        assert HandRank.compare(a, c) == :eq
      end
    end
  end

  property "лучшая рука из семи карт не слабее любой своей пятёрки" do
    check all(cards <- StreamData.uniq_list_of(StreamData.integer(0..51), length: 7)) do
      best = HandRank.best_hand(cards, @holdem)

      assert Enum.all?(Combinatorics.combinations(cards, 5), fn five ->
               HandRank.best_of_five(five, @holdem).score <= best.score
             end)
    end
  end

  property "best_score совпадает со score лучшей руки" do
    check all(cards <- StreamData.uniq_list_of(StreamData.integer(0..51), length: 7)) do
      context = HandRank.context(@holdem)
      candidates = Combinatorics.combinations(cards, 5)

      assert HandRank.best_score(candidates, context) ==
               HandRank.best_of(candidates, context).score
    end
  end

  property "категория и score согласованы: сильнее категория — больше score" do
    check all(left <- five_cards(), right <- five_cards()) do
      order = @holdem.category_order()
      a = HandRank.best_of_five(left, @holdem)
      b = HandRank.best_of_five(right, @holdem)

      left_index = Enum.find_index(order, &(&1 == a.category))
      right_index = Enum.find_index(order, &(&1 == b.category))

      if left_index > right_index, do: assert(a.score > b.score)
    end
  end

  defp score_of(cards), do: HandRank.best_of_five(cards, @holdem).score

  defp shuffled(cards) do
    StreamData.bind(StreamData.integer(), fn seed ->
      StreamData.constant(Enum.sort_by(cards, &:erlang.phash2({&1, seed})))
    end)
  end
end
