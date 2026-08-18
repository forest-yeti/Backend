defmodule BlockPoker.Engine.Deck do
  @moduledoc """
  Колода. Состав задаёт вариант игры: 52 карты у Hold'em, 36 у Short Deck.

  Тасовка — Fisher–Yates на переданном RNG. RNG именно аргумент, а не
  глобальный источник: иначе раздачу нельзя воспроизвести в тесте, а
  подмена глобального seed заражает соседние тесты.
  """

  alias BlockPoker.Engine.{Card, Rng}

  @spec new(module()) :: [Card.t()]
  def new(variant), do: variant.deck()

  @doc "Тасует список карт. Возвращает и продвинутый RNG — он остаётся явным."
  @spec shuffle([Card.t()], Rng.t()) :: {[Card.t()], Rng.t()}
  def shuffle(cards, rng) do
    size = length(cards)

    if size < 2 do
      {cards, rng}
    else
      {tuple, rng} = fisher_yates(List.to_tuple(cards), size - 1, rng)
      {Tuple.to_list(tuple), rng}
    end
  end

  defp fisher_yates(tuple, 0, rng), do: {tuple, rng}

  defp fisher_yates(tuple, index, rng) do
    {swap, rng} = Rng.uniform_below(rng, index + 1)
    tuple = swap(tuple, index, swap)
    fisher_yates(tuple, index - 1, rng)
  end

  defp swap(tuple, index, index), do: tuple

  defp swap(tuple, left, right) do
    left_value = elem(tuple, left)

    tuple
    |> put_elem(left, elem(tuple, right))
    |> put_elem(right, left_value)
  end
end
