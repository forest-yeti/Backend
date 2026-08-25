defmodule Socket.Channels.Admin.GamesChannel do
  @moduledoc """
  Топик `admin:games`: живой список игр всех четырёх режимов.

  Канал подписан на те же топики, что и витрина, — открытие и закрытие
  комнат, изменение состава, ход турниров, — и на каждый сигнал
  перечитывает список у ядра. Собирать его обходом `Registry` или `Lobby`
  здесь запрещено: это `Admin.Games.live_games/1` (§9 задачи 8).

  Перечитывание целиком, а не дельтой, выбрано намеренно: панель смотрит
  один человек, а дельта потребовала бы держать в транспорте копию
  состояния, которой там быть не должно.
  """

  use Phoenix.Channel

  alias BlockPoker.Admin
  alias Socket.Channels.Admin.Guard
  alias Socket.Protocol.Message

  @impl true
  def join("admin:games", _payload, socket) do
    with :ok <- Guard.allow(socket),
         {:ok, games} <- Admin.live_games(socket.assigns.admin_ctx, :all) do
      # На что подписываться, говорит контекст: канал знает, что список
      # живой, но не знает, из чего он собран (§9 задачи 8).
      Enum.each(Admin.games_topics(), &Phoenix.PubSub.subscribe(BlockPoker.PubSub, &1))

      {:ok, %{items: games}, socket}
    else
      {:error, %{} = error} -> {:error, error}
      {:error, code} -> {:error, Message.error(code)}
    end
  end

  @impl true
  def handle_in("list", payload, socket) do
    case Admin.live_games(socket.assigns.admin_ctx, kind(payload)) do
      {:ok, games} -> {:reply, {:ok, %{items: games}}, socket}
      {:error, code} -> Message.error_reply(code, socket)
    end
  end

  def handle_in("ping", payload, socket) do
    {:reply, {:ok, Message.pong(payload)}, socket}
  end

  @impl true
  def handle_info({:room_changed, _summary}, socket), do: refresh(socket)
  def handle_info({:tournament_updated, _tournament_id}, socket), do: refresh(socket)
  def handle_info(:check_session, socket), do: Guard.recheck(socket)
  def handle_info(_message, socket), do: {:noreply, socket}

  defp refresh(socket) do
    case Admin.live_games(socket.assigns.admin_ctx, :all) do
      {:ok, games} -> push(socket, "games", %{items: games})
      {:error, _code} -> :ok
    end

    {:noreply, socket}
  end

  # Что такое режим игры, знает ядро: список видов живёт в `Admin.Games`,
  # и повторять его в канале значило бы завести вторую копию доменной
  # константы (§3 CLAUDE.md). Неизвестное значение означает «все», а не
  # отказ: ронять подписку из-за опечатки в фильтре незачем.
  defp kind(payload), do: Admin.game_kind(payload["kind"])
end
