defmodule BlockPoker.Engine.Rng do
  @moduledoc """
  РСЃС‚РѕС‡РЅРёРє СЃР»СѓС‡Р°Р№РЅРѕСЃС‚Рё РєР°Рє СЏРІРЅС‹Р№ Р°СЂРіСѓРјРµРЅС‚, Р° РЅРµ РіР»РѕР±Р°Р»СЊРЅРѕРµ СЃРѕСЃС‚РѕСЏРЅРёРµ.

  Р РµР°Р»РёР·Р°С†РёСЏ РѕР±СЏР·Р°РЅР° РѕС‚РґР°РІР°С‚СЊ *Р±Р°Р№С‚С‹*; СЂР°РІРЅРѕРјРµСЂРЅРѕРµ С‡РёСЃР»Рѕ РёР· РґРёР°РїР°Р·РѕРЅР°
  СЃС‡РёС‚Р°РµС‚ СЃР°Рј СЌС‚РѕС‚ РјРѕРґСѓР»СЊ (РѕС‚Р±СЂР°СЃС‹РІР°РЅРёРµ, Р° РЅРµ РѕСЃС‚Р°С‚РѕРє РѕС‚ РґРµР»РµРЅРёСЏ вЂ” РѕСЃС‚Р°С‚РѕРє
  СЃРјРµС‰Р°РµС‚ СЂР°СЃРїСЂРµРґРµР»РµРЅРёРµ). РўР°Рє Сѓ СЂРµР°Р»РёР·Р°С†РёРё РѕСЃС‚Р°С‘С‚СЃСЏ СЂРѕРІРЅРѕ РѕРґРЅР° Р·Р°Р±РѕС‚Р°,
  Рё РїРѕРґРјРµРЅРёС‚СЊ РµС‘ РІ С‚РµСЃС‚Р°С… РјРѕР¶РЅРѕ, РЅРёС‡РµРіРѕ РЅРµ РїРµСЂРµРїРёСЃС‹РІР°СЏ.

  RNG РїРµСЂРµРґР°С‘С‚СЃСЏ Рё РІРѕР·РІСЂР°С‰Р°РµС‚СЃСЏ РєР°Рє РєРѕСЂС‚РµР¶ `{module, state}`: Р±РµР· СЃРѕСЃС‚РѕСЏРЅРёСЏ
  seed Р±РµСЃРїРѕР»РµР·РµРЅ, Р° СЂР°Р·РґР°С‡Р° РѕР±СЏР·Р°РЅР° РІРѕСЃРїСЂРѕРёР·РІРѕРґРёС‚СЊСЃСЏ РїРѕ seed (В§10 CLAUDE.md).
  `:rand` РґР»СЏ РєР°СЂС‚ Р·Р°РїСЂРµС‰С‘РЅ вЂ” РѕР±Рµ СЂРµР°Р»РёР·Р°С†РёРё СЃС‚РѕСЏС‚ РЅР° `:crypto`.
  """

  import Bitwise

  @type state :: term()
  @type t :: {module(), state()}

  @callback init(seed :: term()) :: state()
  @callback bytes(state(), pos_integer()) :: {binary(), state()}

  @doc "RNG РїРѕ СѓРјРѕР»С‡Р°РЅРёСЋ: РєСЂРёРїС‚РѕРіСЂР°С„РёС‡РµСЃРєРёР№, РЅРµРІРѕСЃРїСЂРѕРёР·РІРѕРґРёРјС‹Р№."
  @spec default() :: t()
  def default, do: new(BlockPoker.Engine.Rng.Crypto)

  @spec new(module(), term()) :: t()
  def new(module, seed \\ nil), do: {module, module.init(seed)}

  @doc "Р’РѕСЃРїСЂРѕРёР·РІРѕРґРёРјС‹Р№ RNG РґР»СЏ С‚РµСЃС‚РѕРІ Рё РїР°СЂР°Р»Р»РµР»СЊРЅС‹С… С‡Р°РЅРєРѕРІ РњРѕРЅС‚Рµ-РљР°СЂР»Рѕ."
  @spec seeded(term()) :: t()
  def seeded(seed), do: new(BlockPoker.Engine.Rng.Seeded, seed)

  @spec bytes(t(), pos_integer()) :: {binary(), t()}
  def bytes({module, state}, count) do
    {binary, state} = module.bytes(state, count)
    {binary, {module, state}}
  end

  @doc "Р Р°РІРЅРѕРјРµСЂРЅРѕРµ С†РµР»РѕРµ РёР· `0..bound - 1` Р±РµР· СЃРјРµС‰РµРЅРёСЏ."
  @spec uniform_below(t(), pos_integer()) :: {non_neg_integer(), t()}
  def uniform_below(rng, 1), do: {0, rng}

  def uniform_below(rng, bound) when is_integer(bound) and bound > 1 do
    bits = bit_size_for(bound)
    byte_count = div(bits + 7, 8)
    mask = (1 <<< bits) - 1
    draw(rng, bound, byte_count, mask)
  end

  @doc """
  РџРѕСЂРѕР¶РґР°РµС‚ РЅРµР·Р°РІРёСЃРёРјС‹Р№ РґРѕС‡РµСЂРЅРёР№ RNG. РќСѓР¶РµРЅ РїР°СЂР°Р»Р»РµР»СЊРЅС‹Рј С‡Р°РЅРєР°Рј РњРѕРЅС‚Рµ-РљР°СЂР»Рѕ:
  РєР°Р¶РґС‹Р№ С‡Р°РЅРє СЃС‡РёС‚Р°РµС‚ СЃРІРѕРёРј RNG, РЅРѕ РІРµСЃСЊ СЂР°СЃС‡С‘С‚ РѕСЃС‚Р°С‘С‚СЃСЏ С„СѓРЅРєС†РёРµР№ РѕС‚ РѕРґРЅРѕРіРѕ seed.
  """
  @spec split(t(), non_neg_integer()) :: {[t()], t()}
  def split(rng, count) do
    Enum.map_reduce(1..count//1, rng, fn _index, rng ->
      {seed, rng} = bytes(rng, 32)
      {seeded(seed), rng}
    end)
  end

  defp draw(rng, bound, byte_count, mask) do
    {binary, rng} = bytes(rng, byte_count)
    <<value::unsigned-integer-size(^byte_count)-unit(8)>> = binary
    value = value &&& mask

    if value < bound, do: {value, rng}, else: draw(rng, bound, byte_count, mask)
  end

  defp bit_size_for(bound), do: (bound - 1) |> Integer.digits(2) |> length()
end
