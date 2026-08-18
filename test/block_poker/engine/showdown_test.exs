defmodule BlockPoker.Engine.ShowdownTest do
  use ExUnit.Case, async: true

  alias BlockPoker.Engine.{Card, Showdown, Variant}

  @holdem Variant.TexasHoldem

  defp hand(string), do: Card.parse_many!(string)

  describe "определение победителя" do
    test "сильнейшая рука занимает первое место" do
      places =
        Showdown.showdown(
          [{:alice, hand("AS AD")}, {:bob, hand("KS KD")}],
          hand("2C 7H 9S TD 3C"),
          @holdem
        )

      assert Enum.map(places, &{&1.player_id, &1.place}) == [{:alice, 1}, {:bob, 2}]
    end

    test "борд играет за обоих: полная ничья даёт одинаковое место" do
      places =
        Showdown.showdown(
          [{:alice, hand("2C 3D")}, {:bob, hand("2H 3S")}],
          hand("AS AD AC AH KS"),
          @holdem
        )

      assert Enum.map(places, & &1.place) == [1, 1]

      assert Showdown.winners(
               [{:alice, hand("2C 3D")}, {:bob, hand("2H 3S")}],
               hand("AS AD AC AH KS"),
               @holdem
             ) ==
               [:alice, :bob]
    end

    test "после группы ничьих место сдвигается на её размер" do
      places =
        Showdown.showdown(
          [{:alice, hand("KS QD")}, {:bob, hand("KH QC")}, {:carol, hand("2S 3D")}],
          hand("KD QS 9H 7C 4S"),
          @holdem
        )

      assert Enum.map(places, &{&1.player_id, &1.place}) == [
               {:alice, 1},
               {:bob, 1},
               {:carol, 3}
             ]
    end

    test "кикер из руки решает, когда борд одинаков" do
      assert Showdown.winners(
               [{:alice, hand("AS 2D")}, {:bob, hand("KS 2C")}],
               hand("AH KH 9S 7C 4D"),
               @holdem
             ) == [:alice]
    end

    test "рука игрока может вовсе не играть" do
      result = Showdown.evaluate(hand("2C 3D"), hand("AS AD AC AH KS"), @holdem)

      assert result.category == :four_of_a_kind
      assert Enum.sort(result.cards) == Enum.sort(hand("AS AD AC AH KS"))
    end

    test "порядок игроков на входе не влияет на результат" do
      entries = [{:alice, hand("AS AD")}, {:bob, hand("KS KD")}, {:carol, hand("QS QD")}]
      board = hand("2C 7H 9S TD 3C")

      direct = Showdown.showdown(entries, board, @holdem)
      reversed = Showdown.showdown(Enum.reverse(entries), board, @holdem)

      assert Enum.sort_by(direct, & &1.player_id) == Enum.sort_by(reversed, & &1.player_id)
    end
  end

  describe "искусственный вариант" do
    test "из руки берутся ровно две карты, не больше" do
      # У alice в руке три червы, но собрать флеш с тузом нельзя:
      # вариант разрешает взять из руки ровно две карты.
      entries = [{:alice, hand("AH KH QH")}, {:bob, hand("9S 9D 5C")}]
      board = hand("JH TH 9H 7D")

      assert Showdown.winners(entries, board, Variant.Artificial) == [:alice]

      alice = Showdown.evaluate(hand("AH KH QH"), board, Variant.Artificial)
      assert alice.category == :straight_flush
      assert Enum.sort(alice.cards) == Enum.sort(hand("KH QH JH TH 9H"))
      refute Card.parse!("AH") in alice.cards
    end

    test "флеш обходит фулл-хаус по правилам этого варианта" do
      entries = [{:alice, hand("AH 9H 8D")}, {:bob, hand("7S 7D 5C")}]
      board = hand("TH JH 7H TS")

      assert Showdown.evaluate(hand("AH 9H 8D"), board, Variant.Artificial).category == :flush

      assert Showdown.evaluate(hand("7S 7D 5C"), board, Variant.Artificial).category ==
               :full_house

      assert Showdown.winners(entries, board, Variant.Artificial) == [:alice]
    end
  end
end
