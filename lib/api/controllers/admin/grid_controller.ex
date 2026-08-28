defmodule Api.Admin.GridController do
  @moduledoc """
  Сетки режимов: заведение и правка шаблонов, из которых поднимаются
  комнаты и турниры.

  Пара к `GameController` и его противоположность: тот показывает, что
  сейчас происходит в руме, этот — из чего рум состоит.

  Транспорту достаётся ровно его пять дел (§3 CLAUDE.md): разобрать
  параметры, достать личность администратора из `conn.assigns`, позвать
  одну функцию контекста и отрендерить ответ. Ветвления по режиму здесь
  нет: `kind` едет в ядро строкой и разбирается там, а какие поля есть
  у кэша и каких нет у турнира — знание `Admin.Grids`.

  Удаления нет и на уровне маршрутов: шаблон снимается с сетки
  (`archive`) и возвращается (`restore`), а строка остаётся — на неё
  ссылается история раздач.
  """

  use Api, :controller

  alias Api.Admin.AdminParams
  alias BlockPoker.Admin

  action_fallback Api.FallbackController

  def index(conn, params) do
    with {:ok, kind} <- AdminParams.setting_kind(params["kind"]),
         {:ok, filter} <- AdminParams.grid_filter(params),
         {:ok, settings} <- Admin.grids(conn.assigns.admin_ctx, kind, filter) do
      render(conn, :index, settings: settings)
    end
  end

  def meta(conn, _params) do
    with {:ok, meta} <- Admin.grid_meta(conn.assigns.admin_ctx) do
      render(conn, :meta, meta: meta)
    end
  end

  def show(conn, %{"kind" => kind, "id" => id}) do
    with {:ok, kind} <- AdminParams.setting_kind(kind),
         {:ok, setting} <- Admin.grid(conn.assigns.admin_ctx, kind, id) do
      render(conn, :show, setting: setting)
    end
  end

  def create(conn, %{"kind" => kind} = params) do
    with {:ok, kind} <- AdminParams.setting_kind(kind),
         {:ok, setting} <- Admin.create_grid(conn.assigns.admin_ctx, kind, attrs(params)) do
      conn |> put_status(:created) |> render(:show, setting: setting)
    end
  end

  def update(conn, %{"kind" => kind, "id" => id} = params) do
    with {:ok, kind} <- AdminParams.setting_kind(kind),
         {:ok, setting} <- Admin.update_grid(conn.assigns.admin_ctx, kind, id, attrs(params)) do
      render(conn, :show, setting: setting)
    end
  end

  def archive(conn, %{"kind" => kind, "id" => id} = params) do
    with {:ok, kind} <- AdminParams.setting_kind(kind),
         {:ok, setting} <-
           Admin.archive_grid(conn.assigns.admin_ctx, kind, id, params["reason"]) do
      render(conn, :show, setting: setting)
    end
  end

  def restore(conn, %{"kind" => kind, "id" => id}) do
    with {:ok, kind} <- AdminParams.setting_kind(kind),
         {:ok, setting} <- Admin.restore_grid(conn.assigns.admin_ctx, kind, id) do
      render(conn, :show, setting: setting)
    end
  end

  def apply(conn, _params) do
    with {:ok, result} <- Admin.apply_grids(conn.assigns.admin_ctx) do
      render(conn, :apply, result: result)
    end
  end

  # Адрес шаблона едет в пути, а не в теле: `kind` и `id` — это «куда», а
  # не «что». Оставлять их в атрибутах значило бы дать телу запроса шанс
  # переспорить маршрут.
  defp attrs(params), do: Map.drop(params, ["kind", "id"])
end
