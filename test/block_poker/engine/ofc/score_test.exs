defmodule BlockPoker.Engine.Ofc.ScoreTest do
  @moduledoc """
  Скоринг китайского покера: линии, скуп, фолы и роялти.

  Без БД и без процессов — правила дисциплины проверяются как чистые
  функции над структурами.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BlockPoker.Engine.Card
  alias BlockPoker.Engine.Ofc.{Board, Royalties, Score}
  alias BlockPoker.Engine.Variant.TexasHoldem

  @context TexasHoldem

  defp cards(text), do: text |> String.split(" ", trim: true) |> Enum.map(&card/1)

  defp card(<<rank::binary-size(1), suit::binary-size(1)>>), do: card(rank, suit)
  defp card(<<rank::binary-size(2), suit::binary-size(1)>>), do: card(rank, suit)

  defp card(rank, suit) do
    ranks = %{
      "2" => 0,
      "3" => 1,
      "4" => 2,
      "5" => 3,
      "6" => 4,
      "7" => 5,
      "8" => 6,
      "9" => 7,
      "10" => 8,
      "J" => 9,
      "Q" => 10,
      "K" => 11,
      "A" => 12
    }

    Card.new(Map.fetch!(ranks, rank), %{"S" => 0, "H" => 1, "D" => 2, "C" => 3}[suit])
  end

  defp board(top, middle, bottom) do
    %Board{top: cards(top), middle: cards(middle), bottom: cards(bottom)}
  end

  describe "фол" do
    test "определяется ровно правилом bottom >= middle >= top" do
      # Сет сверху при паре в середине: рука усиливается снизу вверх — фол.
      fouled = board("AS AH AD", "2S 2H 5D 7C 9S", "3S 4S 6S 8S 10S")
      assert Board.foul?(fouled, @context)

      # Та же сила боксов в верном порядке фолом не является.
      fine = board("2S 2H 5D", "AS AH AD 7C 9S", "3S 4S 6S 8S 10S")
      refute Board.foul?(fine, @context)
    end

    test "равенство соседних боксов фолом не является" do
      # Две одинаковые по силе пары: правило нестрогое.
      hand = board("2S 3H 4D", "5S 5H 7D 8C 9S", "6S 6H 7C 8D 9H")
      refute Board.foul?(hand, @context)
    end

    test "недособранная рука фолом быть не может" do
      refute Board.foul?(board("AS AH AD", "2S 2H", ""), @context)
    end
  end

  describe "роялти" do
    test "верхний бокс: пара 66 — минимум, пара AA — девять, сет тузов — двадцать два" do
      assert royalty(:top, "6S 6H 2D") == 1
      assert royalty(:top, "AS AH 2D") == 9
      assert royalty(:top, "2S 2H 2D") == 10
      assert royalty(:top, "AS AH AD") == 22
    end

    test "верхний бокс: пара ниже шестёрок премии не даёт" do
      assert royalty(:top, "5S 5H 2D") == 0
      assert royalty(:top, "AS KH QD") == 0
    end

    test "середина платит вдвое против низа на одинаковых комбинациях" do
      assert royalty(:middle, "2S 3H 4D 5C 6S") == 4
      assert royalty(:bottom, "2S 3H 4D 5C 6S") == 2

      assert royalty(:middle, "2S 5S 7S 9S JS") == 8
      assert royalty(:bottom, "2S 5S 7S 9S JS") == 4
    end

    test "роял-флеш отличается от обычного стрит-флеша" do
      assert royalty(:middle, "9S 10S JS QS KS") == 30
      assert royalty(:middle, "10S JS QS KS AS") == 50
      assert royalty(:bottom, "AS 2S 3S 4S 5S") == 15
      assert royalty(:bottom, "10S JS QS KS AS") == 25
    end

    test "фолнувший не получает роялти ни за один бокс" do
      fouled = board("AS AH AD", "2S 2H 5D 7C 9S", "3S 4S 6S 8S 10S")

      assert Royalties.for_board(fouled, @context).total == 0
    end
  end

  describe "попарный расчёт" do
    test "скуп даёт ровно шесть, а не три и не четыре" do
      strong = board("AS AH 2D", "3S 4H 5D 6C 7S", "8S 9H 10D JC QS")
      weak = board("2S 3H 4D", "2H 5S 7D 8C 9H", "3D 5C 6H 8D 10C")

      scores = Score.score(%{1 => strong, 2 => weak}, @context)

      # Три линии плюс скуп плюс роялти пары тузов сверху.
      royalties = Royalties.for_board(strong, @context).total
      assert scores[1].against[2] == 6 + royalties
      assert scores[2].against[1] == -(6 + royalties)
    end

    test "фол против фола — ноль" do
      fouled = board("AS AH AD", "2S 2H 5D 7C 9S", "3S 4S 6S 8S 10S")
      other = board("KS KH KD", "2D 2C 4S 6H 8C", "3H 4C 5H 7D 9C")

      scores = Score.score(%{1 => fouled, 2 => other}, @context)

      assert scores[1].against[2] == 0
      assert scores[2].against[1] == 0
      assert scores[1].total == 0
    end

    test "фол против двоих — минус двенадцать плюс их роялти" do
      fouled = board("AS AH AD", "2S 2H 5D 7C 9S", "3S 4S 6S 8S 10S")
      plain = board("2D 3C 4H", "5S 6H 7D 8C 9S", "10H JD QC KS AC")
      rich = board("6D 6C 7H", "2C 3D 4C 5H 6H", "8H 9D 10C JS QH")

      scores = Score.score(%{1 => fouled, 2 => plain, 3 => rich}, @context)

      plain_royalties = Royalties.for_board(plain, @context).total
      rich_royalties = Royalties.for_board(rich, @context).total

      assert scores[1].total == -(12 + plain_royalties + rich_royalties)
    end
  end

  describe "инвариант нулевой суммы" do
    property "сумма очков двоих всегда равна нулю" do
      check all(boards <- list_of(random_board(), length: 2)) do
        scores = Score.score(%{1 => Enum.at(boards, 0), 2 => Enum.at(boards, 1)}, @context)

        assert scores |> Map.values() |> Enum.map(& &1.total) |> Enum.sum() == 0
      end
    end

    property "сумма очков троих всегда равна нулю" do
      check all(boards <- list_of(random_board(), length: 3)) do
        scores =
          Score.score(
            %{1 => Enum.at(boards, 0), 2 => Enum.at(boards, 1), 3 => Enum.at(boards, 2)},
            @context
          )

        assert scores |> Map.values() |> Enum.map(& &1.total) |> Enum.sum() == 0
      end
    end
  end

  # Случайная раскладка из тринадцати разных карт. Фолы среди них попадаются
  # сами собой — именно они и интересны инварианту.
  defp random_board do
    gen all(deal <- uniq_list_of(integer(0..51), length: 13)) do
      %Board{
        top: Enum.take(deal, 3),
        middle: deal |> Enum.drop(3) |> Enum.take(5),
        bottom: Enum.drop(deal, 8)
      }
    end
  end

  defp royalty(row, text) do
    board =
      case row do
        :top -> board(text, "", "")
        :middle -> board("", text, "")
        :bottom -> board("", "", text)
      end

    Royalties.for_row(row, Board.rank(board, row, @context))
  end
end
