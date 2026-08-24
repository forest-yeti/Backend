defmodule Api.Plugs.Authenticate do
  @moduledoc """
  Проверка токена на HTTP-ручках, требующих личности.

  Тот же токен, что авторизует сокет, — второго механизма аутентификации в
  проекте нет. Плаг отвечает ровно на вопрос «кто это» и кладёт `user_id` в
  `conn.assigns`; на вопрос «можно ли ему» отвечает контекст (§3 CLAUDE.md).

  Токен читается из заголовка `Authorization: Bearer <token>`, а не из
  query-параметра: строка запроса попадает в логи прокси и в историю
  браузера, и токен из неё утекает вместе с ними.
  """

  import Plug.Conn

  alias BlockPoker.Accounts
  alias BlockPoker.ErrorCode

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, token} <- bearer(conn),
         {:ok, user} <- Accounts.verify_socket_token(token) do
      assign(conn, :user_id, user.id)
    else
      {:error, code} -> deny(conn, code)
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _rest] when token != "" -> {:ok, token}
      _other -> {:error, :token_invalid}
    end
  end

  defp deny(conn, code) do
    code = if ErrorCode.valid?(code), do: code, else: :token_invalid
    {status, message} = {ErrorCode.http_status(code), ErrorCode.message(code)}

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{code: to_string(code), message: message}))
    |> halt()
  end
end
