defmodule Api.Plugs.AdminCors do
  @moduledoc """
  CORS для `/admin/*`.

  Панель — отдельное приложение на другом origin, поэтому CORS настраивается
  **явно**, а не отключается: список разрешённых origin'ов приходит из
  конфига, `*` не поддерживается вовсе (§8 задачи 8).

      config :block_poker, :admin_origins, ["https://admin.example.com"]

  Незнакомый origin не получает заголовков — браузер сам не пустит ответ
  в такую страницу. Отдельный `403` для этого не нужен и только выдал бы
  наличие ручки.

  Плаг стоит в `Socket.Endpoint` **до** роутера, а не в пайплайне: у
  предполётного `OPTIONS` маршрута нет, пайплайны до него не доходят, и
  запрос падал бы в `NoRouteError` без единого заголовка. Поэтому же плаг
  сам ограничивает себя путями `/admin/*` — игровые ручки он не трогает.
  """

  import Plug.Conn

  @behaviour Plug

  @allowed_headers "authorization, content-type"
  @allowed_methods "GET, POST, OPTIONS"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["admin" | _rest]} = conn, _opts) do
    case origin(conn) do
      nil -> preflight(conn)
      allowed -> conn |> put_cors(allowed) |> preflight()
    end
  end

  def call(conn, _opts), do: conn

  defp origin(conn) do
    with [origin | _rest] <- get_req_header(conn, "origin"),
         true <- origin in allowed_origins() do
      origin
    else
      _other -> nil
    end
  end

  defp put_cors(conn, origin) do
    conn
    |> put_resp_header("access-control-allow-origin", origin)
    |> put_resp_header("access-control-allow-headers", @allowed_headers)
    |> put_resp_header("access-control-allow-methods", @allowed_methods)
    |> put_resp_header("access-control-max-age", "600")
    # Ответ зависит от origin, и кэш обязан это знать: без `Vary` прокси
    # отдаст заголовки одного origin'а другому.
    |> put_resp_header("vary", "origin")
  end

  # Предполётный запрос до роутера: маршрута под `OPTIONS` нет и заводить
  # его на каждую ручку незачем.
  defp preflight(%Plug.Conn{method: "OPTIONS"} = conn) do
    conn |> send_resp(204, "") |> halt()
  end

  defp preflight(conn), do: conn

  defp allowed_origins, do: Application.get_env(:block_poker, :admin_origins, [])
end
