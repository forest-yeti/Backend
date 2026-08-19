defmodule BlockPoker.Engine.Rabbit do
  @moduledoc """
  Rabbit hunting: карты, которые легли бы на борд, доиграй раздача до ривера.

  Модуль ничего не досдаёт и не тасует. Колода перемешивается **целиком и
  один раз** в `Hand.start/3`, а улицы лишь откусывают от её головы, поэтому
  «что было бы дальше» лежит в `hand.deck` с первого хода. Показ этих карт
  не добавляет в игру ни одного случайного бита и не может задним числом
  изменить сыгранный результат — в этом и состоит вся его безопасность.

  Доступно **только после раздачи, законченной фолдом**. Вскрытие означает,
  что борд доведён до конца и показывать нечего; неполного борда на вскрытии
  не бывает. Всё остальное — раздача идёт, борд полон — отказ.

  Функция чистая и возвращает ровно недостающие улицы. Хвост колоды наружу
  не отдаётся никогда: сохранять его в состоянии стола означало бы держать
  рядом с живой комнатой данные, которых там быть не должно.
  """

  alias BlockPoker.Engine.{Card, Hand}

  @typedoc "Улица и карты, которые пришли бы на ней."
  @type street_cards :: %{street: Hand.street(), cards: [map()]}

  @type error :: :hand_in_progress | :showdown | :board_complete

  @doc """
  Недостающие улицы завершённой раздачи.

  Карты уходят наружу парой `%{rank, suit}`: внутри ядра карта — целое
  число ради скорости, но это представление за пределы движка не выходит.
  """
  @spec runout(Hand.t()) :: {:ok, [street_cards()]} | {:error, error()}
  def runout(%Hand{street: :complete, results: %{showdown?: false}} = hand) do
    case Hand.board_plan(hand) do
      [] -> {:error, :board_complete}
      plan -> {:ok, deal(plan, hand.deck)}
    end
  end

  def runout(%Hand{street: :complete}), do: {:error, :showdown}
  def runout(%Hand{}), do: {:error, :hand_in_progress}

  defp deal(plan, deck) do
    plan
    |> Enum.map_reduce(deck, fn {street, count}, deck ->
      {cards, rest} = Enum.split(deck, count)
      {%{street: street, cards: Enum.map(cards, &Card.to_map/1)}, rest}
    end)
    |> elem(0)
  end
end
