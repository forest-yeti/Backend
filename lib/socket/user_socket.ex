defmodule Socket.UserSocket do
  @moduledoc """
  Аутентификация WebSocket-соединения.

  Токен выдаётся через `POST /api/auth/login` и проверяется здесь, до создания
  соединения. `user_id` кладётся в `socket.assigns` и является единственным
  источником личности для всех каналов — payload'у от клиента не доверяем.
  """

  use Phoenix.Socket

  alias BlockPoker.Accounts
  alias Socket.Protocol.Version

  # channel "lobby", Socket.LobbyChannel
  # channel "table:*", Socket.TableChannel
  # channel "wallet:*", Socket.WalletChannel

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

  @impl true
  def id(%{assigns: %{user_id: user_id}}), do: "user_socket:#{user_id}"
  def id(_socket), do: nil
end
