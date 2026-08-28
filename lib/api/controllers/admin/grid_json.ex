defmodule Api.Admin.GridJSON do
  @moduledoc """
  Рендер сеток панели.

  Карточка приходит из `Admin.Grids` готовой: здесь только время в строку
  и атомы в строки. Ни одного вычисленного поля — границы бай-ина в
  фишках, базовая единица стола и признак «снят с сетки» посчитаны в
  ядре, потому что это арифметика над деньгами и доменные признаки, а не
  вёрстка (§3 CLAUDE.md).
  """

  def index(%{settings: settings}), do: %{items: Enum.map(settings, &render/1)}

  def show(%{setting: setting}), do: render(setting)

  def meta(%{meta: meta}) do
    meta
    |> Map.update!(:defaults, fn defaults -> Map.new(defaults, &default/1) end)
    |> stringify()
  end

  @doc "Что успели перечитать витрины: `ok` либо `unavailable`."
  def apply(%{result: result}), do: stringify(result)

  defp default({kind, card}), do: {to_string(kind), render(card)}

  defp render(card) do
    card
    |> Map.new(fn {key, value} -> {key, value(value)} end)
    |> Map.update(:kind, nil, &to_string/1)
  end

  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, value(v)} end)

  # Атомы наружу едут строками, время — ISO 8601. Отдельный разбор для
  # `Time` и `Date`: расписание турнира это «21:30» и «первое сентября»,
  # а не момент времени.
  defp value(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp value(%Time{} = time), do: Time.to_iso8601(time)
  defp value(%Date{} = date), do: Date.to_iso8601(date)

  defp value(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: to_string(value)

  defp value(value) when is_list(value), do: Enum.map(value, &value/1)
  defp value(value) when is_map(value), do: stringify(value)
  defp value(value), do: value
end
