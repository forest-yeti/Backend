defmodule BlockPoker.Engine.Ofc.TopRank do
  @moduledoc """
  Роспись верхнего бокса: три карты, старшая — пара — сет.

  Стритов и флешей в трёх картах в китайском покере не считают, поэтому
  разбирать масти здесь не нужно вовсе. Всё, чем модуль отличается от
  `HandRank`, — форма руки из трёх рангов вместо пяти; шкала силы общая,
  и её задаёт вариант, а не этот модуль.
  """

  alias BlockPoker.Engine.{Card, HandRank}

  @doc "Оценка ровно трёх карт по шкале варианта."
  @spec evaluate([Card.t()], module() | HandRank.Context.t()) :: HandRank.t()
  def evaluate(cards, context) when length(cards) == 3 do
    ranks = cards |> Enum.map(&Card.rank/1) |> Enum.sort(:desc)
    {category, tiebreakers} = shape(ranks)

    HandRank.build(category, tiebreakers, cards, context)
  end

  # Трёхкарточных форм всего три, и каждая ловится сопоставлением с образцом
  # по тем же соображениям, что и пятикарточные в `HandRank`.
  defp shape([a, a, a]), do: {:three_of_a_kind, [a]}
  defp shape([a, a, k]), do: {:pair, [a, k]}
  defp shape([k, a, a]), do: {:pair, [a, k]}
  defp shape([x, y, z]), do: {:high_card, [x, y, z]}
end
