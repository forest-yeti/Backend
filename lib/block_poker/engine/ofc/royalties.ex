defmodule BlockPoker.Engine.Ofc.Royalties do
  @moduledoc """
  Премия за силу бокса — **данными**, а не числами, разбросанными по коду.

  Роялти начисляются поверх линий и между собой не сравниваются: их платит
  каждый соперник независимо от того, чья рука сильнее. Сильная рука ценна
  против всех, а не только против того, кто оказался слабее.

  Фолнувший роялти не получает, но чужие оплачивает, — поэтому подсчёт для
  мёртвой руки здесь и не начинается: об этом знает `Ofc.Score`.
  """

  alias BlockPoker.Engine.{Card, HandRank}
  alias BlockPoker.Engine.Ofc.Board

  # Верхний бокс: пара от шестёрок и любой сет. Ключ — ранг пары или сета
  # во внутренней шкале (0 — двойка, 12 — туз).
  @top_pair Map.new(4..12, fn rank -> {rank, rank - 3} end)
  @top_trips Map.new(0..12, fn rank -> {rank, rank + 10} end)

  @middle %{
    three_of_a_kind: 2,
    straight: 4,
    flush: 8,
    full_house: 12,
    four_of_a_kind: 20,
    straight_flush: 30,
    royal_flush: 50
  }

  @bottom %{
    straight: 2,
    flush: 4,
    full_house: 6,
    four_of_a_kind: 10,
    straight_flush: 15,
    royal_flush: 25
  }

  @doc "Премия за один бокс. Ноль — комбинация до премии не дотягивает."
  @spec for_row(Board.row(), HandRank.t() | nil) :: non_neg_integer()
  def for_row(_row, nil), do: 0

  def for_row(:top, %HandRank{category: :pair, cards: cards}),
    do: Map.get(@top_pair, pair_rank(cards), 0)

  def for_row(:top, %HandRank{category: :three_of_a_kind, cards: [card | _rest]}),
    do: Map.get(@top_trips, Card.rank(card), 0)

  def for_row(:top, %HandRank{}), do: 0
  def for_row(:middle, %HandRank{} = rank), do: Map.get(@middle, category(rank), 0)
  def for_row(:bottom, %HandRank{} = rank), do: Map.get(@bottom, category(rank), 0)

  @doc """
  Премии всей раскладки по боксам и их сумма. Мёртвая рука не получает
  ничего: фол сжигает роялти целиком, а не по боксам.
  """
  @spec for_board(Board.t(), module() | HandRank.Context.t()) :: %{
          rows: %{Board.row() => non_neg_integer()},
          total: non_neg_integer()
        }
  def for_board(%Board{} = board, context) do
    if Board.foul?(board, context) do
      %{rows: Map.new(Board.rows(), &{&1, 0}), total: 0}
    else
      rows = Map.new(Board.rows(), &{&1, for_row(&1, Board.rank(board, &1, context))})
      %{rows: rows, total: rows |> Map.values() |> Enum.sum()}
    end
  end

  # Роял-флеш отдельной категорией в росписи не существует: это стрит-флеш
  # от туза. Различать их обязана таблица премий, а не `HandRank`, — иначе
  # у варианта появилась бы категория, которой в правилах покера нет.
  defp category(%HandRank{category: :straight_flush, cards: cards}) do
    if Enum.any?(cards, &(Card.rank(&1) == 12)) and
         Enum.any?(cards, &(Card.rank(&1) == 11)),
       do: :royal_flush,
       else: :straight_flush
  end

  defp category(%HandRank{category: category}), do: category

  # Карты приходят отсортированными «сначала то, что делает руку», поэтому
  # ранг пары — ранг первой карты.
  defp pair_rank([card | _rest]), do: Card.rank(card)
end
