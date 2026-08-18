defmodule BlockPoker.Engine.CardSet do
  @moduledoc """
  Набор карт как 52-битная маска в одном integer.

  Нужен в горячем цикле калькулятора: «карта занята?», «убрать известные
  карты из колоды», «объединить руку с бордом» — на списке каждая такая
  операция стоит обхода, на маске это одна битовая инструкция.
  """

  import Bitwise

  alias BlockPoker.Engine.Card

  @type t :: non_neg_integer()

  @spec new() :: t()
  def new, do: 0

  @spec from_list([Card.t()]) :: t()
  def from_list(cards), do: Enum.reduce(cards, 0, fn card, set -> set ||| 1 <<< card end)

  @spec to_list(t()) :: [Card.t()]
  def to_list(set), do: for(card <- 0..51, member?(set, card), do: card)

  @spec put(t(), Card.t()) :: t()
  def put(set, card), do: set ||| 1 <<< card

  @spec delete(t(), Card.t()) :: t()
  def delete(set, card), do: set &&& bnot(1 <<< card)

  @spec member?(t(), Card.t()) :: boolean()
  def member?(set, card), do: (set >>> card &&& 1) == 1

  @spec union(t(), t()) :: t()
  def union(left, right), do: left ||| right

  @spec difference(t(), t()) :: t()
  def difference(left, right), do: left &&& bnot(right)

  @spec intersection(t(), t()) :: t()
  def intersection(left, right), do: left &&& right

  @spec disjoint?(t(), t()) :: boolean()
  def disjoint?(left, right), do: (left &&& right) == 0

  @spec size(t()) :: non_neg_integer()
  def size(set), do: count_bits(set, 0)

  defp count_bits(0, acc), do: acc
  defp count_bits(set, acc), do: count_bits(set &&& set - 1, acc + 1)
end
