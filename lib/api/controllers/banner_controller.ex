defmodule Api.BannerController do
  @moduledoc """
  Баннер места: `GET /api/banners/:place`.

  Почему HTTP, а не сообщение канала (§3 CLAUDE.md): баннер `OnRunApplication`
  показывается на запуске приложения — до логина, до токена и до сокета.
  Тот же случай, что и `GET /api/client/version`. Ответ идемпотентный,
  кэшируемый и ничего в игре не меняет, то есть ни одного свойства, ради
  которых существует канал, у него нет.

  Ручка публичная и токена не требует по той же причине.
  """

  use Api, :controller

  alias BlockPoker.Banners

  action_fallback Api.FallbackController

  def show(conn, %{"place" => place}) do
    with {:ok, banner} <- Banners.get(place) do
      json(conn, banner)
    end
  end
end
