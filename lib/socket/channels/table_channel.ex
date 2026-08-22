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

  require Logger

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

  def handle_in("action", payload, socket) do
    case Message.fetch_action(payload) do
      {:ok, action} ->
        socket.assigns.room_id
        |> Tables.act(socket.assigns.user_id, action, Message.action_seq(payload))
        |> Message.reply(socket)

      {:error, code} ->
        Message.error_reply(code, socket)
    end
  end

  def handle_in("preselect", payload, socket) do
    socket.assigns.room_id
    |> Tables.preselect(socket.assigns.user_id, Map.get(payload, "action"))
    |> Message.reply(socket)
  end

  def handle_in("straddle", payload, socket) do
    case Message.fetch_straddle(payload) do
      {:ok, amount} ->
        socket.assigns.room_id
        |> Tables.straddle(socket.assigns.user_id, amount)
        |> Message.reply(socket)

      {:error, code} ->
        Message.error_reply(code, socket)
    end
  end

  def handle_in("post_blind", payload, socket) do
    socket.assigns.room_id
    |> Tables.request_post(socket.assigns.user_id, Map.get(payload, "post", true) == true)
    |> Message.reply(socket)
  end

  # Замер задержки: канал отвечает сам, не тревожа ни комнату, ни контекст.
  def handle_in("ping", payload, socket) do
    {:reply, {:ok, Message.pong(payload)}, socket}
  end

  def handle_in("reaction", payload, socket) do
    socket.assigns.room_id
    |> Tables.react(socket.assigns.user_id, Map.get(payload, "id"))
    |> Message.reply(socket)
  end

  def handle_in("chat", payload, socket) do
    socket.assigns.room_id
    |> Tables.chat(socket.assigns.user_id, Map.get(payload, "text"))
    |> Message.reply(socket)
  end

  def handle_in("show_cards", payload, socket) do
    socket.assigns.room_id
    |> Tables.show_cards(socket.assigns.user_id, Message.card_indexes(payload))
    |> Message.reply(socket)
  end

  def handle_in("run_it_twice", payload, socket) do
    socket.assigns.room_id
    |> Tables.answer_run_it_twice(socket.assigns.user_id, payload["accept"] == true)
    |> Message.reply(socket)
  end

  # Окно-калькулятор: разбор своей руки по запросу. Канал ничего не считает —
  # берёт готовый разбор у контекста и сериализует.
  def handle_in("hand_insight", _payload, socket) do
    case Tables.hand_insight(socket.assigns.room_id, socket.assigns.user_id) do
      {:ok, insight} -> {:reply, {:ok, %{insight: TableView.insight(insight)}}, socket}
      {:error, code} -> Message.error_reply(code, socket)
    end
  end

  def handle_in("rabbit_hunt", _payload, socket) do
    socket.assigns.room_id
    |> Tables.rabbit_hunt(socket.assigns.user_id)
    |> Message.reply(socket)
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

  def handle_in("cancel_add_chips", _payload, socket) do
    socket.assigns.room_id
    |> Tables.cancel_add_chips(socket.assigns.user_id)
    |> Message.reply(socket)
  end

  def handle_in("start_game", _payload, socket) do
    socket.assigns.room_id
    |> Tables.start_game(socket.assigns.user_id)
    |> Message.reply(socket)
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
    push(socket, event, TableView.event(event, payload))
    {:noreply, socket}
  end

  # Приватное событие адресовано одному игроку: остальные каналы его молча
  # пропускают. Карманные карты не должны попасть в общий топик даже на миг.
  def handle_info({:table_private, user_id, event, payload}, socket) do
    if socket.assigns.user_id == user_id, do: push(socket, event, payload)
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(reason, socket) do
    # Причина закрытия пишется в лог: место после этого показывается столу
    # как «нет связи», и без неё невозможно отличить ушедшего игрока от
    # упавшего канала — а жалоба выглядит одинаково.
    log_terminate(reason, socket)

    # Разрыв соединения — не cash-out: комната держит место grace-период
    # и решает сама, что делать по его истечении.
    #
    # Уборка обязана быть тихой при любом исходе. Комнаты может не быть
    # вовсе — она падает, и это как раз одна из причин, по которым канал
    # закрывается; а `room_id` в `assigns` не появляется, если join отвергли.
    # Падение здесь ничего не чинит: оно лишь засыпает лог вторичными
    # ошибками поверх настоящей.
    case Map.get(socket.assigns, :room_id) do
      nil -> :ok
      room_id -> disconnect_quietly(room_id, socket.assigns.user_id)
    end
  end

  # Обычный уход — это `:normal`, `:shutdown` и `{:shutdown, _}`: закрыли
  # окно, вышли, оборвалась сеть. Всё остальное — падение канала, и оно
  # обязано быть видно.
  defp log_terminate(reason, _socket) when reason in [:normal, :shutdown], do: :ok
  defp log_terminate({:shutdown, _reason}, _socket), do: :ok

  defp log_terminate(reason, socket) do
    Logger.warning(
      "table channel down: room=#{Map.get(socket.assigns, :room_id)} " <>
        "user=#{Map.get(socket.assigns, :user_id)} reason=#{inspect(reason)}"
    )
  end

  defp disconnect_quietly(room_id, user_id) do
    Tables.disconnect(room_id, user_id)
    :ok
  catch
    :exit, _reason -> :ok
  end
end
