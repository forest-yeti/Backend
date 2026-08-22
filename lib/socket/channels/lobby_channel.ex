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

  alias BlockPoker.Accounts
  alias BlockPoker.Tables
  alias BlockPoker.Tables.Lobby
  alias Socket.Protocol.Message
  alias Socket.Views.LobbyView
  alias Socket.Views.OfcLobbyView

  # Разделов витрины два, и `lobby` — только кэш-столы холдема. Столы
  # китайского покера в общую сетку не подмешиваются: у них своя категория
  # и свой топик, и подписчик `lobby` об их существовании не узнаёт.
  @impl true
  def join("lobby", payload, socket), do: join_lobby(:cash, payload, socket)
  def join("lobby:ofc", payload, socket), do: join_lobby(:ofc, payload, socket)

  defp join_lobby(category, payload, socket) do
    case Tables.lobby_query(payload, category) do
      {:ok, query} ->
        :ok = Phoenix.PubSub.subscribe(BlockPoker.PubSub, Lobby.topic(category))
        socket = assign(socket, :lobby_query, query)
        {:ok, render(query, Tables.lobby_snapshot(query)), socket}

      {:error, code} ->
        {:error, Message.error(code)}
    end
  end

  @impl true
  def handle_in("list", payload, socket) do
    case Tables.lobby_query(payload, socket.assigns.lobby_query.category) do
      {:ok, query} ->
        socket = assign(socket, :lobby_query, query)
        {:reply, {:ok, render(query, Tables.lobby_snapshot(query))}, socket}

      {:error, code} ->
        Message.error_reply(code, socket)
    end
  end

  # Замер задержки: канал отвечает сам, не тревожа ни комнату, ни контекст.
  def handle_in("ping", payload, socket) do
    {:reply, {:ok, Message.pong(payload)}, socket}
  end

  # Где игрок уже сидит. Закрытие окна стола место не освобождает, и лобби
  # обязано уметь ответить, куда возвращаться.
  def handle_in("my_seats", _payload, socket) do
    {:reply, {:ok, LobbyView.my_seats(Tables.my_seats(socket.assigns.user_id))}, socket}
  end

  # Смена аватара: клиент шлёт метку строкой, канал только достаёт `user_id`
  # из assigns и зовёт контекст. Список допустимых меток — в ядре.
  def handle_in("set_avatar", payload, socket) do
    case Accounts.set_avatar(socket.assigns.user_id, Map.get(payload, "avatar")) do
      {:ok, user} -> {:reply, {:ok, %{avatar: user.avatar}}, socket}
      {:error, code} -> Message.error_reply(code, socket)
    end
  end

  # Вход по коду: канал отдаёт превью комнаты, садится игрок обычным
  # `join_seat` в топике стола.
  def handle_in("find_by_code", payload, socket) do
    case Tables.find_by_code(Map.get(payload, "code")) do
      {:ok, found} -> {:reply, {:ok, found_room(found)}, socket}
      {:error, code} -> Message.error_reply(code, socket)
    end
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
      push(socket, "lobby_delta", setting(snapshot))
    end

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # Какой витриной рисовать раздел, решает его категория. Набор полей у
  # строк разный — у кэша блайнды, у китайского покера цена очка, — и
  # подмешивать одной форме нули другой было бы враньём в снапшоте.
  defp render(%{category: :ofc}, snapshot), do: OfcLobbyView.render(snapshot)
  defp render(_query, snapshot), do: LobbyView.render(snapshot)

  defp setting(%{category: :ofc} = snapshot), do: OfcLobbyView.setting(snapshot)
  defp setting(snapshot), do: LobbyView.setting(snapshot)

  defp found_room(%{setting: %BlockPoker.OfcGames.OfcSetting{}} = found),
    do: OfcLobbyView.found_room(found)

  defp found_room(found), do: LobbyView.found_room(found)
end
