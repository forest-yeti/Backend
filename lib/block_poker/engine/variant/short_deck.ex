defmodule BlockPoker.Engine.Variant.ShortDeck do
  @moduledoc """
  Short Deck (6+ Hold'em): колода 36 карт, две карманные, борд из пяти,
  лучшая пятёрка — любая из семи карт.

  Из колоды убраны двойки, тройки, четвёрки и пятёрки. Отсюда два отличия
  от холдема, и оба — следствие арифметики, а не вкуса:

    * **флеш выше фулл-хауса.** В масти девять карт вместо тринадцати, и
      собрать флеш стало труднее, чем фулл-хаус;
    * **младший стрит — `A6789`.** Туз играет и старшим, и младшим, но
      колеса `A2345` в этой колоде нет, потому что нет двойки.

  Сет выше стрита **не** поднимаем: такая роспись существует, но игроками
  читается хуже. Если попросят — это одна перестановка в `category_order/0`
  и ноль правок в остальном коде.

  Ставки — анте от всех плюс анте кнопки (`BettingStructure.ButtonAnte`),
  блайндов нет. Почему именно так — §10 задачи 4.
  """

  @behaviour BlockPoker.Engine.Variant

  alias BlockPoker.Engine.BettingStructure
  alias BlockPoker.Engine.Combinatorics

  # Ранги 4..12 — от шестёрки до туза (0 — двойка).
  @deck for rank <- 4..12, suit <- 0..3, do: rank * 4 + suit

  # От TJQKA вниз до 6789T, последним — A6789: туз младший, стрит
  # сравнивается по девятке.
  @straights Enum.map(12..8//-1, fn high -> Enum.to_list(high..(high - 4)//-1) end) ++
               [[7, 6, 5, 4, 12]]

  @impl true
  def id, do: :short_deck

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

  @impl true
  def betting_structure, do: BettingStructure.ButtonAnte
end
