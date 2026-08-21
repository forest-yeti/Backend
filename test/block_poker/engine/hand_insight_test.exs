defmodule BlockPoker.Engine.HandInsightTest do
  use ExUnit.Case, async: true

  alias BlockPoker.Engine.{Card, HandInsight, Variant}

  @holdem Variant.TexasHoldem
  @short_deck Variant.ShortDeck

  defp cards(string), do: Card.parse_many!(string)

  defp analyze(hole, board, variant \\ @holdem),
    do: HandInsight.analyze(cards(hole), cards(board), variant)

  defp shown(insight), do: insight.cards |> Enum.map(&Card.to_string/1) |> Enum.sort()

  defp draw(insight, type), do: Enum.find(insight.draws, &(&1.type == type))

  defp types(insight), do: Enum.map(insight.draws, & &1.type)

  describe "что играет до флопа" do
    test "разномастные картинки — старшая карта" do
      insight = analyze("AS KH", "")

      assert insight.category == :high_card
      assert insight.complete == false
      assert shown(insight) == ["AS"]
    end

    test "карманная пара — пара, и играют обе карты" do
      insight = analyze("7S 7D", "")

      assert insight.category == :pair
      assert shown(insight) == ["7D", "7S"]
    end

    test "до флопа доездов не показываем" do
      assert analyze("AH KH", "").draws == []
    end
  end

  describe "что играет на борде" do
    test "с флопа комбинация собрана из пяти карт" do
      insight = analyze("AS KH", "AD 7C 2S")

      assert insight.category == :pair
      assert insight.complete == true
      assert length(insight.cards) == 5
      # Первыми идут карты, которые руку и делают.
      assert insight.cards |> Enum.take(2) |> Enum.map(&Card.to_string/1) |> Enum.sort() ==
               ["AD", "AS"]
    end

    test "готовый стрит — категория стрита" do
      insight = analyze("9S TH", "JD QC KS")

      assert insight.category == :straight
      assert insight.complete == true
    end
  end

  describe "доезды" do
    test "флеш-дро: девять карт масти" do
      insight = analyze("AH KH", "2H 7H TC")

      assert %{outs: 9} = draw(insight, :flush_draw)

      assert Enum.all?(
               draw(insight, :flush_draw).cards,
               &(Card.suit(&1) == Card.suit(hd(cards("2H"))))
             )
    end

    test "двусторонний стрит-дро: восемь карт двух величин" do
      insight = analyze("9S TH", "8D 7C 2S")

      assert %{outs: 8} = draw(insight, :open_ended)
      assert types(insight) == [:open_ended]
    end

    test "младшая двусторонка: и туз, и шестёрка достраивают одну четвёрку" do
      insight = analyze("2S 3H", "4D 5C KS")

      assert %{outs: 8} = draw(insight, :open_ended)
    end

    test "гатшот: четыре карты одной величины" do
      insight = analyze("9S TH", "8D 6C 2S")

      assert %{outs: 4} = draw(insight, :gutshot)
    end

    test "двойной гатшот: две дырки, восемь карт, но это не двусторонка" do
      insight = analyze("7S 9H", "8D JC 5S")

      assert %{outs: 8} = draw(insight, :double_gutshot)
      assert draw(insight, :open_ended) == nil
    end

    test "флеш-дро и стрит-дро показываются вместе" do
      insight = analyze("AH KH", "QH JS 2H")

      assert draw(insight, :flush_draw)
      assert draw(insight, :gutshot)
    end

    test "карта, закрывающая стрит-флеш, идёт отдельным доездом" do
      insight = analyze("9H TH", "8H JH 2C")

      assert %{outs: 2} = draw(insight, :straight_flush_draw)

      # 7H и QH ушли в стрит-флеш и в обычном флеш-дро не дублируются.
      assert %{outs: 7} = draw(insight, :flush_draw)
    end

    test "у собранной руки того же вида доезда нет" do
      insight = analyze("AH KH", "2H 7H TH")

      assert insight.category == :flush
      assert draw(insight, :flush_draw) == nil
    end

    test "на полном борде доездов нет ни у кого" do
      assert analyze("AH KH", "2H 7H TC 3D 4S").draws == []
    end
  end

  describe "вид покера" do
    test "в короткой колоде стрит A6789 читается как двусторонка" do
      insight = analyze("8S 9H", "7D 6C KS", @short_deck)

      assert %{outs: 8} = draw(insight, :open_ended)
    end

    test "в короткой колоде доезд не считает карт, которых в ней нет" do
      insight = analyze("AH KH", "2H 7H TC", @holdem)
      short = analyze("AH KH", "7H 8H TC", @short_deck)

      assert draw(insight, :flush_draw).outs == 9

      # В колоде 36 карт мастей всего девять, значит доезд короче.
      assert draw(short, :flush_draw).outs == 5
    end
  end
end
