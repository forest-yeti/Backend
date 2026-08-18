defmodule Socket.UserSocket do
  @moduledoc """
  Аутентификация WebSocket-соединения.

  Токен выдаётся через `POST /api/auth/login` и проверяется здесь, до создания
  соединения. `user_id` кладётся в `socket.assigns` и является единственным
  источником личности для всех каналов — payload'у от клиента не доверяем.
  """

  use Phoenix.Socket

  # channel "lobby", Socket.LobbyChannel
  # channel "table:*", Socket.TableChannel
  # channel "wallet:*", Socket.WalletChannel

  @impl true
  def connect(_params, _socket, _connect_info) do
    # TODO: BlockPoker.Accounts.verify_socket_token/1 -> assign(:user_id, id)
    :error
  end

  @impl true
  def id(%{assigns: %{user_id: user_id}}), do: "user_socket:#{user_id}"
  def id(_socket), do: nil
end
