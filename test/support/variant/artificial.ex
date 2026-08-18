defmodule BlockPoker.Engine.Variant.Artificial do
  @moduledoc """
  Искусственный вариант покера, существующий только ради проверки абстракции.

  Он нарочно ломает все допущения холдема: колода 40 карт, три карманные
  карты, борд из четырёх, пятёрка собирается ровно из двух карт руки и трёх
  карт борда, флеш сильнее фулл-хауса, а младший стрит идёт от туза к восьмёрке.

  Это дешевле, чем писать настоящую Omaha или Short Deck, и ловит ровно то же:
  протекли ли допущения холдема в общий код. Если `Showdown` и `Equity`
  работают с этим вариантом без единой правки в `lib`, абстракция верна.
  """

  @behaviour BlockPoker.Engine.Variant

  alias BlockPoker.Engine.Combinatorics

  # Ранги 3..12 — от пятёрки до туза.
  @deck for rank <- 3..12, suit <- 0..3, do: rank * 4 + suit

  @straights Enum.map(12..7//-1, fn high -> Enum.to_list(high..(high - 4)//-1) end) ++
               [[6, 5, 4, 3, 12]]

  @impl true
  def id, do: :artificial

  @impl true
  def deck, do: @deck

  @impl true
  def hole_cards_count, do: 3

  @impl true
  def board_size, do: 4

  @impl true
  def candidate_hands(hole, board) do
    for from_hole <- Combinatorics.combinations(hole, 2),
        from_board <- Combinatorics.combinations(board, 3) do
      from_hole ++ from_board
    end
  end

  @impl true
  def category_order do
    [
      :high_card,
      :pair,
      :two_pair,
      :three_of_a_kind,
      :straight,
      :full_house,
      :flush,
      :four_of_a_kind,
      :straight_flush
    ]
  end

  @impl true
  def straight_sequences, do: @straights

  @impl true
  def pot_split, do: :high
end
