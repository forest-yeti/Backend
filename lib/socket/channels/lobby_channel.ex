defmodule Socket.Channels.LobbyChannel do
  @moduledoc """
  Топик `lobby`: список лимитов, фильтры и быстрый вход.

  Канал парсит payload, берёт `user_id` из `assigns`, зовёт одну функцию
  контекста и рендерит результат. Ни «хватает ли денег», ни «свободно ли
  место», ни «в границах ли бай-ин» здесь нет и быть не может (§3 CLAUDE.md).

  Фильтр подписчика хранится в `assigns` — это подписка, а не игровое
  состояние: что означают `micro` и `six_max` и в каком порядке идут
  лимиты, решает `BlockPoker.Tables.LobbyQuery`.
  """

  use Phoenix.Channel

  alias BlockPoker.Tables
  alias BlockPoker.Tables.Lobby
  alias Socket.Protocol.Message
  alias Socket.Views.LobbyView

  @impl true
  def join("lobby", payload, socket) do
    case Tables.lobby_query(payload) do
      {:ok, query} ->
        :ok = Phoenix.PubSub.subscribe(BlockPoker.PubSub, Lobby.topic())
        socket = assign(socket, :lobby_query, query)
        {:ok, LobbyView.render(Tables.lobby_snapshot(query)), socket}

      {:error, code} ->
        {:error, Message.error(code)}
    end
  end

  @impl true
  def handle_in("list", payload, socket) do
    case Tables.lobby_query(payload) do
      {:ok, query} ->
        socket = assign(socket, :lobby_query, query)
        {:reply, {:ok, LobbyView.render(Tables.lobby_snapshot(query))}, socket}

      {:error, code} ->
        Message.error_reply(code, socket)
    end
  end

  # Замер задержки: канал отвечает сам, не тревожа ни комнату, ни контекст.
  def handle_in("ping", payload, socket) do
    {:reply, {:ok, Message.pong(payload)}, socket}
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
    # Лимит, отсеянный фильтром, до подписчика не доезжает: иначе клиенту
    # пришлось бы решать это самому, то есть знать правила категорий.
    if Tables.lobby_visible?(socket.assigns.lobby_query, snapshot) do
      push(socket, "lobby_delta", LobbyView.setting(snapshot))
    end

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}
end
