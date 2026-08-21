defmodule BlockPoker.Engine.HandInsight do
  @moduledoc """
  Подсказка игроку по его собственной руке: что у него собрано сейчас и
  чем это может стать следующей картой борда.

  Модуль отвечает ровно на два вопроса экрана:

    * **что играет** — категория руки и те карты, которые её образуют.
      До флопа пятёрки не набирается вовсе, поэтому карманные карты
      разбираются отдельно: `AK` — старшая карта, `77` — пара. Это не
      частный случай «ради красоты»: `HandRank` принимает ровно пять
      карт и на двух не определён;
    * **какие есть доезды** — гатшот, двусторонка, двойной гатшот,
      флеш-дро (`Engine.Draw`).

  Считается всё **только по картам владельца и борду**. Чужие карты сюда
  не приходят даже там, где сервер их знает: подсказка обязана совпадать
  с тем, что игрок вправе видеть, иначе она сама становится утечкой.
  Этим она отличается от `Engine.Outs`, который знает весь расклад и
  считает аутов относительно лидера.

  Доезды ищутся перебором оставшихся карт, а не по шаблонам рангов:
  шаблон «четыре подряд — восемь аутов» врёт, как только часть нужных
  карт уже лежит на борде. Отсюда и `Draw.outs` — число реально доступных
  карт, а не константа из учебника.

  Ветвления по виду покера здесь нет: колода, состав пятёрки и список
  стритовых последовательностей приходят из `Variant` (§ `Engine.Variant`).
  """

  alias BlockPoker.Engine.{Card, CardSet, Draw, HandRank, Showdown, Variant}

  @enforce_keys [:category, :cards, :draws]
  defstruct [:category, :cards, :draws, :complete]

  @type t :: %__MODULE__{
          category: atom() | nil,
          cards: [Card.t()],
          draws: [Draw.t()],
          complete: boolean()
        }

  @straight_categories [:straight, :straight_flush]
  @flush_categories [:flush, :straight_flush]

  @doc """
  Разбор руки игрока: собранная комбинация и доезды.

  `complete` — набралась ли настоящая пятикарточная комбинация. До флопа
  он `false`, а `category` при этом всё равно осмысленна (`:pair` или
  `:high_card`) — клиенту незачем знать, сколько карт на борде, чтобы
  подписать экран.
  """
  @spec analyze([Card.t()], [Card.t()], Variant.t() | HandRank.Context.t()) :: t()
  def analyze(hole, board, variant_or_context) do
    context = context(variant_or_context)
    {category, cards, complete} = made(hole, board, context)

    %__MODULE__{
      category: category,
      cards: cards,
      complete: complete,
      draws: draws(hole, board, category, context)
    }
  end

  # --- собранная комбинация -------------------------------------------------

  defp made(hole, board, context) do
    case Showdown.evaluate(hole, board, context) do
      nil -> partial(hole ++ board)
      rank -> {rank.category, rank.cards, true}
    end
  end

  # Меньше пяти карт: стрит и флеш невозможны, остаётся только совпадение
  # рангов. Играют те карты, которые дали лучшую группу.
  defp partial([]), do: {nil, [], false}

  defp partial(cards) do
    groups =
      cards
      |> Enum.group_by(&Card.rank/1)
      |> Enum.sort_by(fn {rank, group} -> {-length(group), -rank} end)
      |> Enum.map(fn {_rank, group} -> group end)

    case groups do
      [[_, _] = first, [_, _] = second | _] -> {:two_pair, first ++ second, false}
      [group | _] -> {group_category(length(group)), group, false}
    end
  end

  defp group_category(1), do: :high_card
  defp group_category(2), do: :pair
  defp group_category(3), do: :three_of_a_kind
  defp group_category(_), do: :four_of_a_kind

  # --- доезды ---------------------------------------------------------------

  defp draws(hole, board, category, context) do
    if board == [] or length(board) >= context.variant.board_size() do
      # До флопа доезда ещё нет (масти и связки — это не незакрытая
      # комбинация), а на полном борде его уже не будет.
      []
    else
      completions = completions(hole, board, context)

      flush_draw(completions, category) ++
        straight_draw(completions, hole, board, category, context)
    end
  end

  # Для каждой карты, которой может лечь борд, — категория получившейся
  # руки. Один прогон на весь разбор: и флеш-дро, и стрит-дро читаются из
  # него, а не считаются заново.
  defp completions(hole, board, context) do
    seen = CardSet.from_list(hole ++ board)

    context.variant.deck()
    |> Enum.reject(&CardSet.member?(seen, &1))
    |> Enum.map(fn card ->
      case Showdown.evaluate(hole, [card | board], context) do
        nil -> {card, nil}
        rank -> {card, rank.category}
      end
    end)
  end

  defp flush_draw(_completions, category) when category in @flush_categories, do: []

  defp flush_draw(completions, _category) do
    {straight_flush, flush} =
      completions
      |> Enum.filter(fn {_card, category} -> category in @flush_categories end)
      |> Enum.split_with(fn {_card, category} -> category == :straight_flush end)

    draw(:straight_flush_draw, straight_flush) ++ draw(:flush_draw, flush)
  end

  defp straight_draw(_completions, _hole, _board, category, _context)
       when category in @straight_categories,
       do: []

  defp straight_draw(completions, hole, board, _category, context) do
    completing =
      Enum.filter(completions, fn {_card, category} -> category in @straight_categories end)

    case completing do
      [] ->
        []

      cards ->
        held = hole ++ board
        draw(straight_type(cards, held, context), cards)
    end
  end

  # Имя доезда — это ответ на вопрос «сколькими разными величинами он
  # закрывается и одну ли четвёрку они достраивают». Двусторонка — две
  # величины поверх **одной и той же** четвёрки (`2345`: туз и шестёрка);
  # двойной гатшот — две величины, каждая со своей четвёркой (`5789J`).
  defp straight_type(cards, held, context) do
    held_ranks = held |> Enum.map(&Card.rank/1) |> MapSet.new()
    ranks = cards |> Enum.map(fn {card, _category} -> Card.rank(card) end) |> Enum.uniq()

    supports =
      for rank <- ranks,
          sequence <- context.variant.straight_sequences(),
          rank in sequence,
          rest = List.delete(sequence, rank),
          Enum.all?(rest, &MapSet.member?(held_ranks, &1)),
          do: {Enum.sort(rest), rank}

    grouped =
      supports
      |> Enum.group_by(fn {rest, _rank} -> rest end, fn {_rest, rank} -> rank end)
      |> Enum.map(fn {_rest, ranks} -> Enum.uniq(ranks) end)

    cond do
      Enum.any?(grouped, &(length(&1) > 1)) -> :open_ended
      length(ranks) > 1 -> :double_gutshot
      true -> :gutshot
    end
  end

  defp draw(_type, []), do: []

  defp draw(type, completions) do
    cards = completions |> Enum.map(fn {card, _category} -> card end) |> Enum.sort()
    [%Draw{type: type, cards: cards, outs: length(cards)}]
  end

  defp context(%HandRank.Context{} = context), do: context
  defp context(variant), do: HandRank.context(variant)
end
