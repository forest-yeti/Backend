defmodule Socket.Channels.Admin.RoomChannel do
  @moduledoc """
  Топик `admin:room:<room_id>`: god-mode на конкретный стол.

  **Временный отладочный инструмент.** Один из трёх файлов наблюдения
  (§13 задачи 8) — сносится вместе с `BlockPoker.Admin.Observer` и
  `Socket.Views.Admin.RoomView` одним коммитом перед публичным релизом.
  Ни списки, ни деньги, ни журнал от этого не пострадают.

  **Наблюдение только читает.** Канал не принимает от клиента ни одного
  мутирующего сообщения — совсем: единственные входящие это `ping` и
  `leave`. Управляющие действия идут по HTTP, где есть `reason` и запись
  в журнале.

  Канал — обычный подписчик, как любой другой: он не заглядывает в
  состояние стола и не знает его правил. Снапшот приходит из ядра уже
  несфильтрованным — `TableView` при этом не получает никакого флага «я
  админ», и тест приватности игрока остаётся зелёным без исключений.
  """

  use Phoenix.Channel

  alias BlockPoker.Admin
  alias Socket.Channels.Admin.Guard
  alias Socket.Protocol.Message
  alias Socket.Views.Admin.RoomView

  @impl true
  def join("admin:room:" <> room_id, _payload, socket) do
    with :ok <- Guard.allow(socket),
         {:ok, %{room: room, feed: feed}} <- Admin.observe(socket.assigns.admin_ctx, room_id) do
      socket = assign(socket, :room_id, room_id)

      {:ok, %{room: RoomView.room(room), feed: Enum.map(feed, &RoomView.intent/1)}, socket}
    else
      {:error, %{} = error} -> {:error, error}
      {:error, code} -> {:error, Message.error(code)}
    end
  end

  @impl true
  def handle_in("ping", payload, socket) do
    {:reply, {:ok, Message.pong(payload)}, socket}
  end

  # Любое другое сообщение молча отвергается кодом, а не выполняется:
  # список входящих у наблюдения закрыт, и расширять его нечем.
  def handle_in(_event, _payload, socket) do
    Message.error_reply(:illegal_action, socket)
  end

  @impl true
  def handle_info({:table_event, event, payload}, socket) do
    push(socket, "room_delta", RoomView.delta(event, payload))
    {:noreply, socket}
  end

  # Приватное событие игрока проходит через наблюдателя как есть: карты
  # адресата и есть то, ради чего режим существует.
  def handle_info({:table_private, user_id, event, payload}, socket) do
    push(socket, "room_delta", RoomView.private(user_id, event, payload))
    {:noreply, socket}
  end

  # Запрос и его результат — два сообщения ленты, а не одно: панель
  # фильтрует их по отдельности, а отклонённый запрос интересен как раз
  # своим результатом. Замер у них общий — он один на обработку.
  def handle_info({:admin_intent, event}, socket) do
    push(socket, "intent", RoomView.intent(event))
    push(socket, "intent_result", RoomView.intent_result(event))
    {:noreply, socket}
  end

  def handle_info(:check_session, socket), do: Guard.recheck(socket)
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    case Map.get(socket.assigns, :room_id) do
      nil -> :ok
      room_id -> Admin.stop_observing(socket.assigns.admin_ctx, room_id)
    end
  end
end
