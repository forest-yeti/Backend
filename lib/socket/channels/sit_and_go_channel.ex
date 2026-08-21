defmodule Socket.Channels.SitAndGoChannel do
  @moduledoc """
  Топик `sit_n_go`: витрина турниров, фильтр по дисциплине и регистрация.

  Канал парсит payload, берёт `user_id` из `assigns`, зовёт одну функцию
  контекста и рендерит результат. Ни «собрался ли пул», ни «хватает ли
  денег на взнос», ни «можно ли ещё отменить» здесь нет и быть не может
  (§3 CLAUDE.md).

  Фильтр подписчика хранится в `assigns` — это подписка, а не игровое
  состояние. Что означает дисциплина и какие они бывают, решает ядро.

  Игра идёт в обычном топике стола (`table:<id>`): турнирный стол — тот же
  `TableServer`, и отдельного канала для него не существует.
  """

  use Phoenix.Channel

  alias BlockPoker.Tables
  alias BlockPoker.Tables.SitAndGoLobby
  alias Socket.Protocol.Message
  alias Socket.Views.SitAndGoView

  @impl true
  def join("sit_n_go", payload, socket) do
    :ok = Phoenix.PubSub.subscribe(BlockPoker.PubSub, SitAndGoLobby.topic())

    game_types = Tables.parse_game_types(payload)
    socket = assign(socket, :game_types, game_types)

    {:ok, SitAndGoView.render(Tables.sit_n_go_snapshot(payload)), socket}
  end

  @impl true
  def handle_in("list", payload, socket) do
    game_types = Tables.parse_game_types(payload)
    socket = assign(socket, :game_types, game_types)

    {:reply, {:ok, SitAndGoView.render(Tables.sit_n_go_snapshot(payload))}, socket}
  end

  # Регистрация: клиент называет только шаблон. Взнос и стартовый стек
  # приходят из него же — выбирать нечего, все входят одинаково.
  def handle_in("register", payload, socket) do
    case Message.fetch_id(payload, "setting_id") do
      {:ok, setting_id} ->
        setting_id
        |> Tables.register(socket.assigns.user_id)
        |> Message.reply(socket)

      {:error, code} ->
        Message.error_reply(code, socket)
    end
  end

  # Отмена регистрации до старта. Право отменить проверяет режим внутри
  # комнаты: спрашивать об этом заранее по снапшоту нельзя — между
  # «посмотрел» и «отменил» турнир успевает начаться.
  def handle_in("unregister", payload, socket) do
    case Message.fetch_id(payload, "room_id") do
      {:ok, room_id} ->
        room_id
        |> Tables.unregister(socket.assigns.user_id)
        |> Message.reply(socket)

      {:error, code} ->
        Message.error_reply(code, socket)
    end
  end

  # Замер задержки: канал отвечает сам, не тревожа ни комнату, ни контекст.
  def handle_in("ping", payload, socket) do
    {:reply, {:ok, Message.pong(payload)}, socket}
  end

  @impl true
  def handle_info({:sit_n_go_update, snapshot}, socket) do
    # Шаблон, отсеянный фильтром, до подписчика не доезжает: иначе клиенту
    # пришлось бы решать это самому, то есть знать правила фильтрации.
    if Tables.sit_n_go_visible?(socket.assigns.game_types, snapshot) do
      push(socket, "sit_n_go_delta", SitAndGoView.setting(snapshot))
    end

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}
end
