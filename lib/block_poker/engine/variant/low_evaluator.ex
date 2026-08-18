defmodule BlockPoker.Engine.Variant.LowEvaluator do
  @moduledoc """
  Вторая шкала для hi-lo вариантов.

  Оценщик обязан возвращать `HandRank`, у которого **больший** `score`
  означает лучшую младшую руку: перевёрнутая шкала прячется здесь, чтобы
  сравнение выше по стеку оставалось одной операцией и не знало, high
  оно сравнивает или low.

  Реализаций в этой задаче нет — Omaha Hi-Lo не пишем. Behaviour объявлен,
  потому что от него зависит форма `Showdown`, а форму дешевле проверить
  сейчас, чем переделывать потом.
  """

  alias BlockPoker.Engine.{Card, HandRank}

  @callback best_low(candidates :: [[Card.t()]], HandRank.Context.t()) ::
              {:ok, HandRank.t()} | :not_qualified
end
