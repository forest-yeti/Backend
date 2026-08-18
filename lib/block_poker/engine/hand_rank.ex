defmodule BlockPoker.Engine.HandRank do
  @moduledoc """
  Сила пятикарточной комбинации как одно число.

  Сравнение рук — целочисленное сравнение `score`; равные `score` означают
  **точную** ничью. Кортеж `{категория, кикеры}` здесь не годится: порядок
  категорий зависит от варианта (в Short Deck флеш выше фулл-хауса), и если
  ordering зашит в форму кортежа, каждый такой вариант требует ветвления
  в местах сравнения. Когда ordering вшивается в число при оценке, сравнение
  не знает про правила вовсе.

  `score = индекс_категории * 2^20 + тайбрейкеры`, тайбрейкеры — до пяти
  рангов по 4 бита.

  Оценка ничего не знает ни про борд, ни про карманные карты: на входе
  просто пять карт. Это не эстетика — китайский покер раскладывает 13 карт
  на три ряда без борда вообще, и примитив, завязанный на «hole + board»,
  туда не переиспользуется.
  """

  import Bitwise

  alias BlockPoker.Engine.{Card, Combinatorics}

  @category_shift 20

  @enforce_keys [:score, :category, :cards]
  defstruct [:score, :category, :cards]

  @type t :: %__MODULE__{
          score: non_neg_integer(),
          category: atom(),
          cards: [Card.t()]
        }

  defmodule Context do
    @moduledoc """
    Развёрнутые правила варианта: индексы категорий и маски стритов.

    Считается один раз на расчёт и передаётся в горячий цикл. Дёргать
    коллбэки варианта на каждую из миллионов оценок — заметная часть
    бюджета из §8 задачи.
    """

    @enforce_keys [:variant, :categories, :straights]
    defstruct [:variant, :categories, :straights]

    @type t :: %__MODULE__{
            variant: module(),
            categories: %{atom() => non_neg_integer()},
            straights: [{non_neg_integer(), 0..12}]
          }
  end

  @doc "Разворачивает правила варианта в форму, удобную горячему циклу."
  @spec context(module()) :: Context.t()
  def context(variant) do
    categories =
      variant.category_order()
      |> Enum.with_index()
      |> Map.new()

    straights =
      Enum.map(variant.straight_sequences(), fn [high | _] = sequence ->
        {Enum.reduce(sequence, 0, fn rank, mask -> mask ||| 1 <<< rank end), high}
      end)

    %Context{variant: variant, categories: categories, straights: straights}
  end

  @doc "Оценка ровно пяти карт."
  @spec best_of_five([Card.t()], module() | Context.t()) :: t()
  def best_of_five(cards, variant_or_context)

  def best_of_five(cards, %Context{} = context) when length(cards) == 5 do
    {category, tiebreakers} = classify(cards, context)

    %__MODULE__{
      score: score(category, tiebreakers, context),
      category: category,
      cards: sort_cards(cards, category, tiebreakers)
    }
  end

  def best_of_five(cards, variant), do: best_of_five(cards, context(variant))

  @doc """
  Лучшая пятёрка из набора карт: перебор всех `C(n, 5)`.

  Перебор наивный сознательно — корректность важнее скорости, а тесты,
  зафиксировавшие поведение, потом становятся гарантией эквивалентности
  для lookup-таблиц.
  """
  @spec best_hand([Card.t()], module() | Context.t()) :: t() | nil
  def best_hand(cards, %Context{} = context) do
    cards
    |> Combinatorics.combinations(5)
    |> best_of(context)
  end

  def best_hand(cards, variant), do: best_hand(cards, context(variant))

  @doc "Лучшая из готовых пятёрок-кандидатов."
  @spec best_of([[Card.t()]], Context.t()) :: t() | nil
  def best_of([], _context), do: nil

  def best_of(candidates, %Context{} = context) do
    Enum.reduce(candidates, nil, fn candidate, best ->
      rank = best_of_five(candidate, context)

      if best == nil or rank.score > best.score, do: rank, else: best
    end)
  end

  @doc """
  Только число: без структуры и без списка карт.

  Горячий цикл эквити выкидывает миллионы `HandRank` в GC, если этого
  не сделать, — а нужен ему исключительно `score`.
  """
  @spec best_score([[Card.t()]], Context.t()) :: non_neg_integer() | nil
  def best_score([], _context), do: nil

  def best_score(candidates, %Context{} = context) do
    Enum.reduce(candidates, -1, fn candidate, best ->
      {category, tiebreakers} = classify(candidate, context)
      score = score(category, tiebreakers, context)

      if score > best, do: score, else: best
    end)
  end

  @doc "Сравнение рук: `:gt`, `:eq` или `:lt`."
  @spec compare(t(), t()) :: :gt | :eq | :lt
  def compare(%__MODULE__{score: left}, %__MODULE__{score: right}) do
    cond do
      left > right -> :gt
      left < right -> :lt
      true -> :eq
    end
  end

  defp classify(cards, %Context{} = context) do
    ranks = cards |> Enum.map(&Card.rank/1) |> Enum.sort(:desc)

    case shape(ranks) do
      # Пять разных рангов — единственный случай, когда ещё возможны флеш
      # и стрит. Для остальных рук их даже не проверяем.
      :distinct -> distinct(cards, ranks, context)
      paired -> paired
    end
  end

  # Разбор рангов, отсортированных по убыванию. Пятикарточных форм всего
  # девять, и каждая ловится сопоставлением с образцом: карта частот здесь
  # обошлась бы в лишнюю аллокацию на каждую из миллионов оценок.
  defp shape([a, a, a, a, k]), do: {:four_of_a_kind, [a, k]}
  defp shape([k, a, a, a, a]), do: {:four_of_a_kind, [a, k]}
  defp shape([a, a, a, b, b]), do: {:full_house, [a, b]}
  defp shape([b, b, a, a, a]), do: {:full_house, [a, b]}
  defp shape([a, a, a, x, y]), do: {:three_of_a_kind, [a, x, y]}
  defp shape([x, a, a, a, y]), do: {:three_of_a_kind, [a, x, y]}
  defp shape([x, y, a, a, a]), do: {:three_of_a_kind, [a, x, y]}
  defp shape([a, a, b, b, k]), do: {:two_pair, [a, b, k]}
  defp shape([a, a, k, b, b]), do: {:two_pair, [a, b, k]}
  defp shape([k, a, a, b, b]), do: {:two_pair, [a, b, k]}
  defp shape([a, a, x, y, z]), do: {:pair, [a, x, y, z]}
  defp shape([x, a, a, y, z]), do: {:pair, [a, x, y, z]}
  defp shape([x, y, a, a, z]), do: {:pair, [a, x, y, z]}
  defp shape([x, y, z, a, a]), do: {:pair, [a, x, y, z]}
  defp shape([_, _, _, _, _]), do: :distinct

  defp distinct(cards, ranks, context) do
    flush? = flush?(cards)
    straight_high = straight_high(ranks, context.straights)

    cond do
      flush? and straight_high -> {:straight_flush, [straight_high]}
      flush? -> {:flush, ranks}
      straight_high -> {:straight, [straight_high]}
      true -> {:high_card, ranks}
    end
  end

  defp flush?([first | rest]) do
    suit = Card.suit(first)
    Enum.all?(rest, fn card -> Card.suit(card) == suit end)
  end

  defp straight_high(ranks, straights) do
    mask = Enum.reduce(ranks, 0, fn rank, mask -> mask ||| 1 <<< rank end)

    Enum.find_value(straights, fn {straight_mask, high} ->
      if straight_mask == mask, do: high
    end)
  end

  defp score(category, tiebreakers, %Context{categories: categories}) do
    index =
      case Map.fetch(categories, category) do
        {:ok, index} ->
          index

        :error ->
          raise ArgumentError,
                "вариант не объявил категорию #{inspect(category)} в category_order/0"
      end

    tiebreak =
      tiebreakers
      |> Enum.reduce(0, fn rank, acc -> acc * 16 + rank end)
      |> bsl((5 - length(tiebreakers)) * 4)

    (index <<< @category_shift) + tiebreak
  end

  # Карты в порядке, в котором рука читается: сначала то, что её делает.
  defp sort_cards(cards, category, [high]) when category in [:straight, :straight_flush] do
    # Ранги выше старшей карты стрита уходят в конец: в `A2345` туз замыкает
    # комбинацию, а не открывает её. То же верно для `A6789` в Short Deck.
    Enum.sort_by(cards, fn card ->
      rank = Card.rank(card)
      if rank > high, do: {1, -rank}, else: {0, -rank}
    end)
  end

  defp sort_cards(cards, _category, _tiebreakers) do
    counts = cards |> Enum.map(&Card.rank/1) |> Enum.frequencies()
    Enum.sort_by(cards, fn card -> {-Map.fetch!(counts, Card.rank(card)), -Card.rank(card)} end)
  end
end
