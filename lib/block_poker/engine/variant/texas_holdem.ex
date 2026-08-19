defmodule BlockPoker.Engine.Variant.TexasHoldem do
  @moduledoc """
  Техасский холдем: полная колода, две карманные карты, борд из пяти,
  лучшая пятёрка — любая из семи карт.
  """

  @behaviour BlockPoker.Engine.Variant

  alias BlockPoker.Engine.Combinatorics

  @deck Enum.to_list(0..51)

  # От старшего стрита к младшему; последним — колесо A2345, где туз младший.
  @straights Enum.map(12..4//-1, fn high -> Enum.to_list(high..(high - 4)//-1) end) ++
               [[3, 2, 1, 0, 12]]

  @impl true
  def id, do: :texas_holdem

  @impl true
  def deck, do: @deck

  @impl true
  def hole_cards_count, do: 2

  @impl true
  def board_size, do: 5

  @impl true
  def candidate_hands(hole, board), do: Combinatorics.combinations(hole ++ board, 5)

  @impl true
  def category_order do
    [
      :high_card,
      :pair,
      :two_pair,
      :three_of_a_kind,
      :straight,
      :flush,
      :full_house,
      :four_of_a_kind,
      :straight_flush
    ]
  end

  @impl true
  def straight_sequences, do: @straights

  @impl true
  def pot_split, do: :high

  @impl true
  def betting_structure, do: BlockPoker.Engine.BettingStructure.Blinds
end
