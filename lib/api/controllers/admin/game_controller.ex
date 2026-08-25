defmodule Api.Admin.GameController do
  @moduledoc """
  Живые игры всех четырёх режимов.

  Один эндпоинт с фильтром по `kind`, а не четыре: список собирает
  `Admin.Games.live_games/1`, а обходить `Registry` или `Lobby` из
  контроллера запрещено (§9 задачи 8). Ветвления по режиму здесь нет —
  различия живут в `GameMode` и в ядре.
  """

  use Api, :controller

  alias Api.Admin.AdminParams
  alias BlockPoker.Admin

  action_fallback Api.FallbackController

  def index(conn, params) do
    with {:ok, kind} <- AdminParams.kind(params["kind"]),
         {:ok, games} <- Admin.live_games(conn.assigns.admin_ctx, kind) do
      render(conn, :index, games: games)
    end
  end

  def show(conn, %{"kind" => kind, "id" => id}) do
    with {:ok, kind} <- AdminParams.kind(kind),
         {:ok, game} <- Admin.game_card(conn.assigns.admin_ctx, kind, id) do
      render(conn, :show, game: game)
    end
  end
end
