defmodule Socket.UserSocket do
  @moduledoc """
  Аутентификация WebSocket-соединения.

  Токен выдаётся через `POST /api/auth/login` и проверяется здесь, до создания
  соединения. `user_id` кладётся в `socket.assigns` и является единственным
  источником личности для всех каналов — payload'у от клиента не доверяем.
  """

  use Phoenix.Socket

  alias BlockPoker.Accounts
  alias BlockPoker.ErrorCode
  alias Socket.Protocol.Version

  channel "lobby", Socket.Channels.LobbyChannel

  # Разделов витрины два, и второй — китайский покер. Топик `lobby:ofc`
  # обслуживает тот же канал: без этой строки сокет его просто не
  # маршрутизирует, и клиент получает отказ вместо списка столов.
  channel "lobby:*", Socket.Channels.LobbyChannel
  channel "sit_n_go", Socket.Channels.SitAndGoChannel
  channel "table:*", Socket.Channels.TableChannel
  channel "wallet:*", Socket.Channels.WalletChannel

  @impl true
  def connect(params, socket, _connect_info) do
    with :ok <- Version.check(params["protocol_vsn"]),
         {:ok, user} <- Accounts.verify_socket_token(params["token"] || "") do
      {:ok,
       socket
       |> assign(:user_id, user.id)
       |> assign(:protocol_vsn, params["protocol_vsn"] || Version.current())}
    else
      {:error, code} -> {:error, %{code: Atom.to_string(code)}}
    end
  end

  @doc """
  Отказ в handshake. Без этого обработчика Phoenix отвечает пустым `403`,
  и клиент не может отличить просроченный токен от устаревшего протокола:
  в первом случае надо обновить токен, во втором — само приложение.
  """
  def handle_error(conn, %{code: code}) when is_binary(code) do
    case ErrorCode.fetch(code) do
      {:ok, error} -> send_error(conn, error, code)
      # Неизвестный код — не повод падать в обработчике отказа: клиент
      # получит штатный 403, как если бы обработчика не было вовсе.
      :error -> Plug.Conn.send_resp(conn, 403, "")
    end
  end

  def handle_error(conn, _reason), do: Plug.Conn.send_resp(conn, 403, "")

  defp send_error(conn, error, code) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      ErrorCode.http_status(error),
      Jason.encode!(%{code: code, message: ErrorCode.message(error)})
    )
  end

  @impl true
  def id(%{assigns: %{user_id: user_id}}), do: "user_socket:#{user_id}"
  def id(_socket), do: nil
end
