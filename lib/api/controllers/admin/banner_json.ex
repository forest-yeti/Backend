defmodule Api.Admin.BannerJSON do
  @moduledoc """
  Рендер баннеров панели.

  Карточка приходит из контекста готовой: панели остаётся отдать её как
  есть, приведя время к строке.
  """

  def index(%{banners: %{items: items} = page}) do
    Map.put(page, :items, Enum.map(items, &render/1))
  end

  def show(%{banner: banner}), do: render(banner)

  defp render(banner), do: Map.update!(banner, :updated_at, &at/1)

  defp at(nil), do: nil
  defp at(%DateTime{} = at), do: DateTime.to_iso8601(at)
end
