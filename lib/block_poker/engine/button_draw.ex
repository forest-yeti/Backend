defmodule BlockPoker.Engine.ButtonDraw do
  @moduledoc """
  Розыгрыш кнопки открытой сдачей по карте (§5 задачи 3).

  Смысл не в механике — её решил бы один вызов RNG, — а в доверии: позиция
  это деньги, и игрок должен видеть, что она досталась не по решению сервера.
  Поэтому карты открытые и одинаковые для всех зрителей.

  Тайбрейк по масти (`♠ > ♥ > ♦ > ♣`) избавляет от пересдачи: полного
  совпадения двух карт не бывает, значит и ветки «сдаём заново» быть не должно.

  Функция универсальна: турнирный стол разыгрывает кнопку ровно так же.
  Колода берётся из варианта — Short Deck разыгрывает своими 36 картами.
  """

  alias BlockPoker.Engine.{Card, Deck, Rng, Variant}

  @type drawn :: %{seat: pos_integer(), card: Card.t()}

  @doc """
  Сдаёт по одной карте на место в переданном порядке и отдаёт место,
  получившее кнопку, вместе со всеми открытыми картами.

  Порядок сдачи — это порядок `seats`; клиент восстанавливает анимацию
  из порядка элементов результата, отдельного индекса не нужно.
  """
  @spec draw([pos_integer()], Variant.t(), Rng.t()) :: {pos_integer(), [drawn()], Rng.t()}
  def draw(seats, variant, rng) when is_list(seats) and seats != [] do
    {deck, rng} = variant |> Deck.new() |> Deck.shuffle(rng)

    drawn =
      seats
      |> Enum.zip(deck)
      |> Enum.map(fn {seat, card} -> %{seat: seat, card: card} end)

    {winner(drawn), drawn, rng}
  end

  @doc "Место со старшей картой: сначала ранг, при равенстве — масть."
  @spec winner([drawn()]) :: pos_integer()
  def winner(drawn), do: Enum.max_by(drawn, &strength(&1.card)).seat

  # Ранг важнее масти, поэтому он в кортеже первым. Масть в `Card` пронумерована
  # от старшей (пики = 0) к младшей, значит для сравнения её знак меняется.
  defp strength(card), do: {Card.rank(card), -Card.suit(card)}
end
