defmodule Socket.Channels.LobbyChannel do
  @moduledoc """
  Топик `lobby`: список лимитов и быстрый вход.

  Канал парсит payload, берёт `user_id` из `assigns`, зовёт одну функцию
  контекста и рендерит результат. Ни «хватает ли денег», ни «свободно ли
  место», ни «в границах ли бай-ин» здесь нет и быть не может (§3 CLAUDE.md).
  """

  use Phoenix.Channel

  alias BlockPoker.Tables
  alias BlockPoker.Tables.Lobby
  alias Socket.Protocol.Message
  alias Socket.Views.LobbyView

  @impl true
  def join("lobby", _payload, socket) do
    :ok = Phoenix.PubSub.subscribe(BlockPoker.PubSub, Lobby.topic())
    {:ok, LobbyView.render(Tables.lobby_snapshot()), socket}
  end

  @impl true
  def handle_in("list", _payload, socket) do
    {:reply, {:ok, LobbyView.render(Tables.lobby_snapshot())}, socket}
  end

  def handle_in("quick_seat", payload, socket) do
    with {:ok, setting_id} <- Message.fetch_id(payload, "setting_id"),
         {:ok, buy_in} <- Message.fetch_amount(payload, "buy_in") do
      setting_id
      |> Tables.quick_seat(socket.assigns.user_id, buy_in, entry: Message.entry(payload))
      |> Message.reply(socket)
    else
      {:error, code} -> Message.error_reply(code, socket)
    end
  end

  @impl true
  def handle_info({:lobby_update, snapshot}, socket) do
    push(socket, "lobby_delta", LobbyView.setting(snapshot))
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}
end
