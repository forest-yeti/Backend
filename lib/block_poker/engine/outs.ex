defmodule BlockPoker.Engine.Outs do
  @moduledoc """
  РђСѓС‚С‹: РєР°СЂС‚С‹, РєРѕС‚РѕСЂС‹Рµ РїРµСЂРµРІРѕРґСЏС‚ РёРіСЂРѕРєР° РёР· В«РЅРµ Р»РёРґРёСЂСѓРµС‚В» РІ В«Р»РёРґРёСЂСѓРµС‚ РёР»Рё
  РґРµР»РёС‚ Р±Р°РЅРєВ», РїСЂРёРґСЏ **СЃР»РµРґСѓСЋС‰РµР№** РєР°СЂС‚РѕР№ Р±РѕСЂРґР°.

  РўРѕРЅРєРѕСЃС‚Рё, Р·Р°С„РёРєСЃРёСЂРѕРІР°РЅРЅС‹Рµ СЏРІРЅРѕ:

    * СЃС‡С‘С‚ РёРґС‘С‚ СЂРѕРІРЅРѕ РЅР° РѕРґРЅСѓ РєР°СЂС‚Сѓ РІРїРµСЂС‘Рґ вЂ” РёРЅР°С‡Рµ В«С‚СЂРё С‚СѓР·Р°В» РїРµСЂРµСЃС‚Р°С‘С‚ Р±С‹С‚СЊ
      СЃРїРёСЃРєРѕРј РєР°СЂС‚ Рё РїСЂРµРІСЂР°С‰Р°РµС‚СЃСЏ РІ РєРѕРјР±РёРЅР°С†РёСЋ РёР· РґРІСѓС… СѓР»РёС†;
    * С‚РѕР»СЊРєРѕ РґР»СЏ РёРіСЂРѕРєРѕРІ СЃ РёР·РІРµСЃС‚РЅС‹РјРё РєР°СЂС‚Р°РјРё: РїСЂРѕС‚РёРІ РЅРµРёР·РІРµСЃС‚РЅРѕР№ СЂСѓРєРё
      Р»РёРґРµСЂСЃС‚РІРѕ РЅРµ РѕРїСЂРµРґРµР»РµРЅРѕ;
    * РЅР° СЂРёРІРµСЂРµ Р°СѓС‚РѕРІ РЅРµС‚ РЅРё Сѓ РєРѕРіРѕ вЂ” РєР°СЂС‚ Р±РѕР»СЊС€Рµ РЅРµ Р±СѓРґРµС‚;
    * РєР°СЂС‚Р°, РґР°СЋС‰Р°СЏ СЃРїР»РёС‚ РёР· РїСЂРѕРёРіСЂС‹С€Р°, вЂ” С‚РѕР¶Рµ Р°СѓС‚: РїРѕР»РѕРІРёРЅР° Р±Р°РЅРєР° СЌС‚Рѕ
      СѓР»СѓС‡С€РµРЅРёРµ;
    * В«Р°РЅС‚Рё-Р°СѓС‚С‹В» РЅРµ СЃС‡РёС‚Р°РµРј: Сѓ Р»РёРґРµСЂР° СЃРїРёСЃРѕРє Р°СѓС‚РѕРІ РїСѓСЃС‚.
  """

  alias BlockPoker.Engine.{Card, CardSet, HandRank, Out, Showdown, Variant}

  @type player_id :: term()

  @doc """
  РђСѓС‚С‹ РєР°Р¶РґРѕРіРѕ РёРіСЂРѕРєР° СЃ РёР·РІРµСЃС‚РЅС‹РјРё РєР°СЂС‚Р°РјРё. Р’РѕР·РІСЂР°С‰Р°РµС‚ РєР°СЂС‚Сѓ
  `player_id => [Out.t()]`; Сѓ Р»РёРґРµСЂРѕРІ СЃРїРёСЃРѕРє РїСѓСЃС‚.
  """
  @spec compute(
          [{player_id(), [Card.t()] | :unknown}],
          [Card.t()],
          Variant.t() | HandRank.Context.t(),
          [Card.t()]
        ) :: %{player_id() => [Out.t()]}
  def compute(hands, board, variant_or_context, dead_cards \\ []) do
    context = context(variant_or_context)
    known = Enum.filter(hands, fn {_id, hole} -> is_list(hole) end)
    empty = Map.new(known, fn {id, _hole} -> {id, []} end)

    with true <- length(known) > 1,
         missing when missing > 0 <- context.variant.board_size() - length(board),
         leaders when leaders != [] <- Showdown.winners(known, board, context) do
      remaining = remaining_cards(known, board, dead_cards, context)

      known
      |> Enum.map(fn {id, _hole} ->
        {id, outs_for(id, known, board, remaining, leaders, context)}
      end)
      |> Map.new()
    else
      _ -> empty
    end
  end

  defp outs_for(id, hands, board, remaining, leaders, context) do
    if id in leaders do
      []
    else
      remaining
      |> Enum.filter(fn card -> id in Showdown.winners(hands, [card | board], context) end)
      |> group_by_rank()
    end
  end

  defp group_by_rank(cards) do
    cards
    |> Enum.group_by(&Card.rank/1)
    |> Enum.sort_by(fn {rank, _cards} -> -rank end)
    |> Enum.map(fn {rank, cards} ->
      cards = Enum.sort(cards)
      %Out{rank: rank + 2, cards: cards, count: length(cards)}
    end)
  end

  defp remaining_cards(hands, board, dead_cards, context) do
    seen =
      hands
      |> Enum.flat_map(fn {_id, hole} -> hole end)
      |> Enum.concat(board)
      |> Enum.concat(dead_cards)
      |> CardSet.from_list()

    Enum.reject(context.variant.deck(), &CardSet.member?(seen, &1))
  end

  defp context(%HandRank.Context{} = context), do: context
  defp context(variant), do: HandRank.context(variant)
end
