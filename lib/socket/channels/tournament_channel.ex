defmodule Socket.Channels.TournamentChannel do
  @moduledoc """
  Топики `tournaments` (витрина) и `tournament:<id>` (инстанс).

  Канал парсит payload, берёт `user_id` из `assigns`, зовёт одну функцию
  контекста и рендерит результат. Ни «можно ли ещё войти», ни «хватает ли
  денег», ни «открыта ли поздняя регистрация» здесь нет и быть не может
  (§3 CLAUDE.md): всё это решает ядро в момент запроса.

  Персональные фильтры («мои турниры», «куда пускает мой билет») считает
  тоже ядро — канал лишь передаёт ему `user_id` из сокета. В payload
  идентификатор не приходит и приходить не должен: подписаться на чужие
  турниры строкой в `join` нельзя.

  Игра идёт в обычном топике стола (`table:<room_id>`): турнирный стол —
  тот же `TableServer`, и отдельного канала для раздачи не существует.
  Этот канал про то, что **над** столом: отсчёт, уровень, перерыв,
  пересадка, место.
  """

  use Phoenix.Channel

  alias BlockPoker.Tables.LobbyQuery
  alias BlockPoker.Tournaments
  alias BlockPoker.Tournaments.TournamentServer
  alias Socket.Protocol.Message
  alias Socket.Views.TournamentView

  @impl true
  def join("tournaments", payload, socket) do
    :ok = Phoenix.PubSub.subscribe(BlockPoker.PubSub, Tournaments.lobby_topic())

    with {:ok, query} <- LobbyQuery.parse(payload, :tournament) do
      socket = assign(socket, :query, query)

      {:ok, TournamentView.render(Tournaments.lobby(query, socket.assigns.user_id)), socket}
    else
      {:error, code} -> {:error, Message.error(code)}
    end
  end

  # Топик инстанса: отсчёт до старта, уровень, перерывы, вылеты.
  # Подписаться может кто угодно — турнир смотрят и не участвуя, — а
  # приватного в нём ничего нет: карт он не знает вовсе.
  def join("tournament:" <> tournament_id, _payload, socket) do
    case Tournaments.get_tournament(tournament_id) do
      {:ok, _tournament} ->
        :ok = Phoenix.PubSub.subscribe(BlockPoker.PubSub, Tournaments.topic(tournament_id))

        {:ok, snapshot(tournament_id), assign(socket, :tournament_id, tournament_id)}

      {:error, _reason} ->
        {:error, Message.error(:not_found)}
    end
  end

  @impl true
  def handle_in("list", payload, socket) do
    with {:ok, query} <- LobbyQuery.parse(payload, :tournament) do
      socket = assign(socket, :query, query)
      entries = Tournaments.lobby(query, socket.assigns.user_id)

      {:reply, {:ok, TournamentView.render(entries)}, socket}
    else
      {:error, code} -> Message.error_reply(code, socket)
    end
  end

  # Карточка читается по нажатию и не пушится: лидерборд, обновляющийся
  # на каждом вылете, — это квадратичный трафик из лобби.
  def handle_in("tournament_card", payload, socket) do
    with {:ok, tournament_id} <- Message.fetch_id(payload, "tournament_id") do
      tournament_id
      |> Tournaments.card(offset: offset(payload))
      |> case do
        {:ok, card} -> {:reply, {:ok, TournamentView.card(card)}, socket}
        {:error, code} -> Message.error_reply(code, socket)
      end
    else
      {:error, code} -> Message.error_reply(code, socket)
    end
  end

  # Клиент называет только инстанс и способ оплаты: суммы берутся из
  # шаблона, выбирать нечего.
  def handle_in("register", payload, socket) do
    with {:ok, tournament_id} <- Message.fetch_id(payload, "tournament_id") do
      tournament_id
      |> Tournaments.register(socket.assigns.user_id, pay_with: pay_with(payload))
      |> case do
        {:ok, entry} ->
          {:reply, {:ok, %{entry_id: entry.id, entry_number: entry.entry_number}}, socket}

        {:error, code} ->
          Message.error_reply(error_code(code), socket)
      end
    else
      {:error, code} -> Message.error_reply(code, socket)
    end
  end

  def handle_in("unregister", payload, socket) do
    with {:ok, tournament_id} <- Message.fetch_id(payload, "tournament_id") do
      tournament_id
      |> Tournaments.unregister(socket.assigns.user_id)
      |> case do
        :ok -> {:reply, :ok, socket}
        {:error, code} -> Message.error_reply(error_code(code), socket)
      end
    else
      {:error, code} -> Message.error_reply(code, socket)
    end
  end

  def handle_in("reentry", _payload, socket) do
    socket.assigns.tournament_id
    |> Tournaments.take_reentry(socket.assigns.user_id)
    |> case do
      {:ok, entry} -> {:reply, {:ok, entry}, socket}
      {:error, code} -> Message.error_reply(error_code(code), socket)
    end
  end

  def handle_in("addon", _payload, socket) do
    socket.assigns.tournament_id
    |> Tournaments.take_addon(socket.assigns.user_id)
    |> case do
      {:ok, result} -> {:reply, {:ok, result}, socket}
      {:error, code} -> Message.error_reply(error_code(code), socket)
    end
  end

  def handle_in("tournament_info", _payload, socket) do
    {:reply, {:ok, snapshot(socket.assigns.tournament_id)}, socket}
  end

  # Замер задержки: канал отвечает сам, не тревожа ни ядро, ни процесс.
  def handle_in("ping", payload, socket) do
    {:reply, {:ok, Message.pong(payload)}, socket}
  end

  @impl true
  def handle_info({:tournament_event, event, payload}, socket) do
    push(socket, event, TournamentView.event(event, payload))
    {:noreply, socket}
  end

  # Витрина: инстанс изменился — перечитываем строку и отдаём, если она
  # проходит фильтр подписчика. Отсеянное до клиента не доезжает: иначе
  # ему пришлось бы знать правила фильтрации.
  def handle_info({:tournament_updated, _tournament_id}, %{assigns: %{query: query}} = socket) do
    entries = Tournaments.lobby(query, socket.assigns.user_id)

    push(socket, "lobby_delta", TournamentView.render(entries))

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp snapshot(tournament_id) do
    case TournamentServer.whereis(tournament_id) do
      nil ->
        # Процесс ещё не поднят (турнир анонсирован, но регистрация не
        # открыта) — отдаём то, что знает БД.
        {:ok, tournament} = Tournaments.get_tournament(tournament_id)

        TournamentView.entry(BlockPoker.Tournaments.LobbyEntry.build(tournament))

      pid ->
        TournamentView.state(TournamentServer.state(pid))
    end
  end

  defp pay_with(%{"pay_with" => "ticket"}), do: :ticket
  defp pay_with(_payload), do: :money

  defp offset(%{"offset" => offset}) when is_integer(offset) and offset >= 0, do: offset
  defp offset(_payload), do: 0

  # Ядро возвращает коды ошибок из единого списка; changeset означает,
  # что данные не прошли валидацию, и наружу это уходит одним кодом.
  defp error_code(code) when is_atom(code), do: code
  defp error_code(_other), do: :validation_failed
end
