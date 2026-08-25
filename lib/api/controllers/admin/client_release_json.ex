defmodule Api.Admin.ClientReleaseJSON do
  @moduledoc """
  Рендер сборок клиента.

  Карточка приходит из контекста готовой: панели остаётся отдать её как
  есть, приведя время к строке.
  """

  def index(%{releases: %{items: items} = page}) do
    page
    |> Map.put(:items, Enum.map(items, &render/1))
  end

  def show(%{release: release}), do: render(release)

  defp render(release) do
    release
    |> Map.update!(:published_at, &at/1)
    |> Map.update!(:inserted_at, &at/1)
  end

  defp at(nil), do: nil
  defp at(%DateTime{} = at), do: DateTime.to_iso8601(at)
end
