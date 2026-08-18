defmodule Socket.Channels.TableChannel do
  @moduledoc """
  Топик `table:<room_id>`: посадка, уход, докупка и стрим состояния комнаты.

  Проверка «этот игрок вправе так сделать» живёт в контексте, а не здесь:
  канал знает, *кто* подключён (`socket.assigns.user_id`), но не решает,
  *можно ли* ему. Убрать отсюда Phoenix — и останется список вызовов
  `Tables.*`; это и есть критерий из §3 CLAUDE.md.

  Игровое состояние в `assigns` не держим: там только `user_id`, `room_id`
  и версия протокола. Источник истины — процесс комнаты.
  """

  use Phoenix.Channel

  alias BlockPoker.Tables
  alias BlockPoker.Tables.TableServer
  alias Socket.Protocol.Message
  alias Socket.Views.TableView

  @impl true
  def join("table:" <> room_id, _payload, socket) do
    case Tables.room_state(room_id) do
      {:ok, room} ->
        :ok = Phoenix.PubSub.subscribe(BlockPoker.PubSub, TableServer.topic(room_id))
        socket = assign(socket, :room_id, room_id)
        room = returned_to_seat(room, room_id, socket.assigns.user_id)
        {:ok, TableView.render(room, socket.assigns.user_id), socket}

      {:error, code} ->
        {:error, Message.error(code)}
    end
  end

  # Подключение к столу — это и есть возвращение игрока: место держалось
  # grace-период, и без этого вызова оно так и осталось бы `disconnected`,
  # пока таймер не выключит игрока из игры. Наблюдатель просто не сидит,
  # для него `reconnect` вернёт `:not_seated`, и снапшот берётся как есть.
  defp returned_to_seat(room, room_id, user_id) do
    case Tables.reconnect(room_id, user_id) do
      {:ok, reconnected} -> reconnected
      {:error, _reason} -> room
    end
  end

  @impl true
  def handle_in("join_seat", payload, socket) do
    with {:ok, seat} <- Message.fetch_seat(payload, "seat"),
         {:ok, buy_in} <- Message.fetch_amount(payload, "buy_in") do
      socket.assigns.room_id
      |> Tables.join_seat(socket.assigns.user_id, seat, buy_in, entry: Message.entry(payload))
      |> Message.reply(socket)
    else
      {:error, code} -> Message.error_reply(code, socket)
    end
  end

  def handle_in("leave_seat", _payload, socket) do
    socket.assigns.room_id
    |> Tables.leave_seat(socket.assigns.user_id)
    |> Message.reply(socket)
  end

  def handle_in("add_chips", payload, socket) do
    case Message.fetch_amount(payload, "amount") do
      {:ok, amount} ->
        socket.assigns.room_id
        |> Tables.add_chips(socket.assigns.user_id, amount)
        |> Message.reply(socket)

      {:error, code} ->
        Message.error_reply(code, socket)
    end
  end

  def handle_in("sit_out", _payload, socket) do
    socket.assigns.room_id
    |> Tables.sit_out(socket.assigns.user_id)
    |> Message.reply(socket)
  end

  def handle_in("sit_in", _payload, socket) do
    socket.assigns.room_id
    |> Tables.sit_in(socket.assigns.user_id)
    |> Message.reply(socket)
  end

  def handle_in("table_state", _payload, socket) do
    case Tables.room_state(socket.assigns.room_id) do
      {:ok, room} -> {:reply, {:ok, TableView.render(room, socket.assigns.user_id)}, socket}
      {:error, code} -> Message.error_reply(code, socket)
    end
  end

  @impl true
  def handle_info({:table_event, event, payload}, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    # Разрыв соединения — не cash-out: комната держит место grace-период
    # и решает сама, что делать по его истечении.
    Tables.disconnect(socket.assigns.room_id, socket.assigns.user_id)
    :ok
  end
end
