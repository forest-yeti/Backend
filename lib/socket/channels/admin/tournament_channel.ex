defmodule Socket.Channels.Admin.TournamentChannel do
  @moduledoc """
  Топик `admin:tournament:<id>`: ход конкретного турнира — уровни,
  перерывы, балансировка, вылеты.

  Только чтение, как и наблюдение за столом: единственное входящее
  сообщение — `ping`. Пауза, возобновление и отмена турнира идут по HTTP,
  где есть `reason` и запись в журнале.

  Карточка приходит из ядра посчитанной: канал подписан на события
  турнира и на каждое перечитывает её у контекста, а сам ничего не
  считает и в состояние турнира не заглядывает (§9 задачи 8).
  """

  use Phoenix.Channel

  alias BlockPoker.Admin
  alias Socket.Channels.Admin.Guard
  alias Socket.Protocol.Message

  @impl true
  def join("admin:tournament:" <> tournament_id, _payload, socket) do
    with :ok <- Guard.allow(socket),
         {:ok, card} <- Admin.game_card(socket.assigns.admin_ctx, :mtt, tournament_id) do
      :ok = Phoenix.PubSub.subscribe(BlockPoker.PubSub, Admin.tournament_topic(tournament_id))
      socket = assign(socket, :tournament_id, tournament_id)

      {:ok, card, socket}
    else
      {:error, %{} = error} -> {:error, error}
      {:error, code} -> {:error, Message.error(code)}
    end
  end

  @impl true
  def handle_in("ping", payload, socket) do
    {:reply, {:ok, Message.pong(payload)}, socket}
  end

  def handle_in(_event, _payload, socket) do
    Message.error_reply(:illegal_action, socket)
  end

  @impl true
  def handle_info({:tournament_event, event, payload}, socket) do
    push(socket, "tournament_delta", %{event: event, payload: payload})

    # Событие говорит, что изменилось; карточка — во что это сложилось.
    # Панели нужно и то и другое: лента объясняет, снимок показывает.
    case Admin.game_card(socket.assigns.admin_ctx, :mtt, socket.assigns.tournament_id) do
      {:ok, card} -> push(socket, "tournament_state", card)
      {:error, _code} -> :ok
    end

    {:noreply, socket}
  end

  def handle_info(:check_session, socket), do: Guard.recheck(socket)
  def handle_info(_message, socket), do: {:noreply, socket}
end
