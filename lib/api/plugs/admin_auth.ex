defmodule Api.Plugs.AdminAuth do
  @moduledoc """
  Проверка админского токена на ручках `/admin/*`.

  Плаг отвечает ровно на вопрос «кто это»: сверяет подпись токена и кладёт
  в `conn.assigns` собранный `%Admin.Context{}`. На вопрос «можно ли ему»
  отвечает контекст — роль проверяется внутри каждой публичной функции
  `BlockPoker.Admin`, а не здесь (§9 задачи 8).

  Токен читается из `Authorization: Bearer <token>`, а не из query: строка
  запроса попадает в логи прокси и в историю браузера.
  """

  import Plug.Conn

  alias BlockPoker.Admin
  alias BlockPoker.Admin.Context
  alias BlockPoker.ErrorCode

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, token} <- bearer(conn),
         {:ok, %{admin: admin, session: session}} <- Admin.authorize(token) do
      assign(conn, :admin_ctx, %Context{
        admin_id: admin.id,
        session_id: session.id,
        ip: Api.Plugs.AdminAuth.client_ip(conn)
      })
    else
      {:error, code} -> deny(conn, code)
    end
  end

  @doc "Адрес запроса строкой — он же уходит в запись журнала действий."
  @spec client_ip(Plug.Conn.t()) :: String.t()
  def client_ip(%Plug.Conn{remote_ip: remote_ip}), do: remote_ip |> :inet.ntoa() |> to_string()

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _rest] when token != "" -> {:ok, token}
      _other -> {:error, :token_invalid}
    end
  end

  defp deny(conn, code) do
    code = if ErrorCode.valid?(code), do: code, else: :token_invalid

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      ErrorCode.http_status(code),
      Jason.encode!(%{code: to_string(code), message: ErrorCode.message(code)})
    )
    |> halt()
  end
end
