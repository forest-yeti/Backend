defmodule Socket.AdminSocket do
  @moduledoc """
  Отдельный сокет панели администратора: `/admin/socket`.

  Игровой `UserSocket` не трогается вообще. Токен проверяется админской
  солью, поэтому игровой токен здесь не проходит, а админский — там
  (§6 задачи 8).

  В `assigns` кладутся только `admin_ctx` и версия протокола. Игрового
  состояния в них нет (§3 CLAUDE.md): источник истины по столу — процесс
  комнаты, и канал ходит к нему через контекст.

  Адрес соединения берётся из `connect_info`, а не из payload: он уходит
  в записи журнала, и доверять в нём клиенту нечему.
  """

  use Phoenix.Socket

  alias BlockPoker.Admin
  alias BlockPoker.Admin.Context
  alias BlockPoker.ErrorCode
  alias Socket.Protocol.Version

  channel "admin:games", Socket.Channels.Admin.GamesChannel
  channel "admin:room:*", Socket.Channels.Admin.RoomChannel
  channel "admin:tournament:*", Socket.Channels.Admin.TournamentChannel

  @impl true
  def connect(params, socket, connect_info) do
    with :ok <- Version.check(params["protocol_vsn"]),
         {:ok, %{admin: admin, session: session}} <- Admin.authorize(params["token"] || "") do
      ctx = %Context{
        admin_id: admin.id,
        session_id: session.id,
        ip: peer_ip(connect_info)
      }

      {:ok,
       socket
       |> assign(:admin_ctx, ctx)
       |> assign(:protocol_vsn, params["protocol_vsn"] || Version.current())}
    else
      {:error, code} -> {:error, %{code: Atom.to_string(code)}}
    end
  end

  @doc """
  Отказ в handshake с понятным кодом: без этого обработчика панель не
  отличит просроченный токен от отозванной сессии — в первом случае надо
  продлить пару, во втором вернуться на экран логина.
  """
  def handle_error(conn, %{code: code}) when is_binary(code) do
    case ErrorCode.fetch(code) do
      {:ok, error} -> send_error(conn, error, code)
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

  # Сессия у каждого соединения своя: отзыв одной не должен рвать
  # остальные, а `id/1` — это и есть то, чем Phoenix рвёт соединения
  # пачкой.
  @impl true
  def id(%{assigns: %{admin_ctx: %Context{session_id: session_id}}}),
    do: "admin_socket:#{session_id}"

  def id(_socket), do: nil

  defp peer_ip(%{peer_data: %{address: address}}), do: address |> :inet.ntoa() |> to_string()
  defp peer_ip(_connect_info), do: "0.0.0.0"
end
