defmodule BlockPoker.Tables.TableServer do
  @moduledoc """
  Комната — процесс и единственный владелец своего состояния (§1.3 CLAUDE.md).

  Здесь только оркестрация: мутации состояния считает чистый `RoomState`,
  политику между раздачами — `GameMode`, розыгрыш кнопки — `Engine.ButtonDraw`.
  Сам сервер отвечает за атомарность, таймеры и рассылку событий.

  **В кошелёк сервер не ходит.** Бай-ин и cash-out делает вызывающий процесс
  между двумя вызовами сюда (резерв → деньги → подтверждение), иначе одна
  медленная транзакция останавливала бы весь стол.

  Таймеры — `Process.send_after` с `deadline_ref`: просроченный ref
  игнорируется, поэтому перезапуск комнаты во время анимации не приводит
  к двойному старту раздачи. В тестах таймеры не отсчитываются реальным
  временем — режим `timers: :manual` плюс `fire_timer/2` (§11 CLAUDE.md).
  """

  use GenServer, restart: :temporary

  alias BlockPoker.Engine.{ButtonDraw, Rng}
  alias BlockPoker.Engine.Variant.Registry, as: VariantRegistry
  alias BlockPoker.Tables.{RoomState, Seat, TableRegistry}
  alias Phoenix.PubSub

  @pubsub BlockPoker.PubSub
  @rooms_topic "tables:rooms"

  defmodule State do
    @moduledoc false
    @enforce_keys [:room, :game_mode, :timer_mode, :rng]
    defstruct [:room, :game_mode, :timer_mode, :rng, timers: %{}]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    GenServer.start_link(__MODULE__, opts, name: TableRegistry.via(room_id))
  end

  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(room_id), do: "table:#{room_id}"

  @doc "Топик, на котором лобби слышит изменения занятости комнат."
  @spec rooms_topic() :: String.t()
  def rooms_topic, do: @rooms_topic

  @spec state(GenServer.server()) :: RoomState.t()
  def state(room), do: GenServer.call(room, :state)

  @spec summary(GenServer.server()) :: map()
  def summary(room), do: GenServer.call(room, :summary)

  @doc "Первый шаг посадки: место закрепляется за игроком до похода в кошелёк."
  @spec reserve_seat(
          GenServer.server(),
          Ecto.UUID.t(),
          pos_integer() | :first_free,
          pos_integer()
        ) ::
          {:ok, %{reservation_id: String.t(), seat: pos_integer()}} | {:error, atom()}
  def reserve_seat(room, user_id, seat, buy_in) do
    GenServer.call(room, {:reserve_seat, user_id, seat, buy_in})
  end

  @spec confirm_seat(GenServer.server(), String.t(), pos_integer(), RoomState.entry()) ::
          {:ok, Seat.t()} | {:error, atom()}
  def confirm_seat(room, reservation_id, amount, entry) do
    GenServer.call(room, {:confirm_seat, reservation_id, amount, entry})
  end

  @spec release_seat(GenServer.server(), String.t()) :: :ok
  def release_seat(room, reservation_id),
    do: GenServer.call(room, {:release_seat, reservation_id})

  @spec begin_leave(GenServer.server(), Ecto.UUID.t()) ::
          {:ok, %{ref: String.t(), stack: non_neg_integer()}} | {:error, atom()}
  def begin_leave(room, user_id), do: GenServer.call(room, {:begin_leave, user_id})

  @spec finish_leave(GenServer.server(), String.t()) :: :ok
  def finish_leave(room, ref), do: GenServer.call(room, {:finish_leave, ref})

  @spec cancel_leave(GenServer.server(), String.t(), non_neg_integer()) :: :ok
  def cancel_leave(room, ref, stack), do: GenServer.call(room, {:cancel_leave, ref, stack})

  @spec validate_add_chips(GenServer.server(), Ecto.UUID.t(), pos_integer()) ::
          {:ok, String.t()} | {:error, atom()}
  def validate_add_chips(room, user_id, amount) do
    GenServer.call(room, {:validate_add_chips, user_id, amount})
  end

  @spec commit_add_chips(GenServer.server(), Ecto.UUID.t(), pos_integer()) ::
          {:ok, Seat.t()} | {:error, atom()}
  def commit_add_chips(room, user_id, amount) do
    GenServer.call(room, {:commit_add_chips, user_id, amount})
  end

  @spec sit_out(GenServer.server(), Ecto.UUID.t()) :: :ok | {:error, atom()}
  def sit_out(room, user_id), do: GenServer.call(room, {:sit_out, user_id})

  @spec sit_in(GenServer.server(), Ecto.UUID.t()) :: :ok | {:error, atom()}
  def sit_in(room, user_id), do: GenServer.call(room, {:sit_in, user_id})

  @spec disconnect(GenServer.server(), Ecto.UUID.t()) :: :ok | {:error, atom()}
  def disconnect(room, user_id), do: GenServer.call(room, {:disconnect, user_id})

  @spec reconnect(GenServer.server(), Ecto.UUID.t()) :: {:ok, Seat.t()} | {:error, atom()}
  def reconnect(room, user_id), do: GenServer.call(room, {:reconnect, user_id})

  @doc "Перевод комнаты в `:draining`: шаблон выключен, новых игроков не пускаем."
  @spec drain(GenServer.server()) :: :ok
  def drain(room), do: GenServer.call(room, :drain)

  @doc """
  Прогон таймера вручную — только для тестов: реальное время в тестах
  не отсчитывается, `Process.sleep` запрещён (§10 CLAUDE.md).
  """
  @spec fire_timer(GenServer.server(), term()) :: :ok | {:error, :no_such_timer}
  def fire_timer(room, key), do: GenServer.call(room, {:fire_timer, key})

  @impl true
  def init(opts) do
    setting = Keyword.fetch!(opts, :setting)
    room_id = Keyword.fetch!(opts, :room_id)

    state = %State{
      room: RoomState.new(room_id, setting),
      game_mode: Keyword.get(opts, :game_mode, BlockPoker.GameMode.Cash),
      timer_mode: Keyword.get(opts, :timers, :real),
      rng: Keyword.get_lazy(opts, :rng, &Rng.default/0)
    }

    {:ok, state, {:continue, :announce}}
  end

  @impl true
  def handle_continue(:announce, state) do
    announce(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state.room, state}

  def handle_call(:summary, _from, state), do: {:reply, RoomState.summary(state.room), state}

  def handle_call({:reserve_seat, user_id, seat, buy_in}, _from, state) do
    with {:ok, seat_number} <- pick_seat(state.room, seat),
         :ok <- RoomState.validate_buy_in(state.room, buy_in),
         reservation_id = new_ref(),
         {:ok, room} <- RoomState.reserve(state.room, seat_number, user_id, reservation_id) do
      state = put_room(state, room)
      announce(state)
      {:reply, {:ok, %{reservation_id: reservation_id, seat: seat_number}}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:confirm_seat, reservation_id, amount, entry}, _from, state) do
    case RoomState.confirm(state.room, reservation_id, amount, entry) do
      {:ok, room, seat} ->
        state = state |> put_room(room) |> maybe_start_game()
        announce(state)
        broadcast(state, "seat_taken", %{seat: seat.number, status: seat.status})
        {:reply, {:ok, seat}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:release_seat, reservation_id}, _from, state) do
    state = put_room(state, RoomState.release(state.room, reservation_id))
    announce(state)
    {:reply, :ok, state}
  end

  def handle_call({:begin_leave, user_id}, _from, state) do
    ref = new_ref()

    case RoomState.begin_leave(state.room, user_id, ref) do
      {:ok, room, stack} ->
        {:reply, {:ok, %{ref: ref, stack: stack}}, put_room(state, room)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:finish_leave, ref}, _from, state) do
    state =
      state
      |> put_room(RoomState.finish_leave(state.room, ref))
      |> cancel_timers_for_gone_seats()
      |> maybe_stop_game()

    announce(state)
    broadcast(state, "seat_left", %{})
    {:reply, :ok, state}
  end

  def handle_call({:cancel_leave, ref, stack}, _from, state) do
    {:reply, :ok, put_room(state, RoomState.cancel_leave(state.room, ref, stack))}
  end

  def handle_call({:validate_add_chips, user_id, amount}, _from, state) do
    with {:ok, seat} <- fetch_seat(state.room, user_id),
         :ok <- ensure_between_hands(state.room),
         :ok <- RoomState.validate_buy_in(state.room, amount, seat.stack) do
      {:reply, {:ok, new_ref()}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:commit_add_chips, user_id, amount}, _from, state) do
    case RoomState.add_chips(state.room, user_id, amount) do
      {:ok, room, seat} ->
        state =
          state |> put_room(room) |> cancel_timer({:rebuy, seat.number}) |> maybe_start_game()

        announce(state)
        broadcast(state, "chips_added", %{seat: seat.number, stack: seat.stack})
        {:reply, {:ok, seat}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:sit_out, user_id}, _from, state) do
    reply_with(state, RoomState.sit_out(state.room, user_id))
  end

  def handle_call({:sit_in, user_id}, _from, state) do
    reply_with(state, RoomState.sit_in(state.room, user_id))
  end

  def handle_call({:disconnect, user_id}, _from, state) do
    case RoomState.disconnect(state.room, user_id) do
      {:ok, room} ->
        seat = RoomState.find_seat(room, user_id)

        state =
          state
          |> put_room(room)
          |> schedule({:grace, seat.number}, room.setting.disconnect_grace_ms)

        broadcast(state, "seat_disconnected", %{seat: seat.number})
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:reconnect, user_id}, _from, state) do
    case RoomState.reconnect(state.room, user_id) do
      {:ok, room, seat} ->
        state = state |> put_room(room) |> cancel_timer({:grace, seat.number})
        broadcast(state, "seat_reconnected", %{seat: seat.number})
        {:reply, {:ok, seat}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:drain, _from, state) do
    state = put_room(state, RoomState.mark_draining(state.room))
    announce(state)
    {:reply, :ok, state}
  end

  def handle_call({:fire_timer, key}, _from, state) do
    case Map.fetch(state.timers, key) do
      {:ok, {ref, _timer}} -> {:reply, :ok, handle_timeout(key, ref, state)}
      :error -> {:reply, {:error, :no_such_timer}, state}
    end
  end

  @impl true
  def handle_info({:table_timeout, key, ref}, state) do
    {:noreply, handle_timeout(key, ref, state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # --- таймеры -------------------------------------------------------------

  defp handle_timeout(key, ref, state) do
    # Просроченный ref — след отменённого таймера; молча игнорируем.
    case Map.fetch(state.timers, key) do
      {:ok, {^ref, _timer}} -> do_timeout(key, %{state | timers: Map.delete(state.timers, key)})
      _other -> state
    end
  end

  # Grace-период истёк: место освобождается, фишки возвращать некому —
  # это делает `Tables`, поэтому наружу уходит событие.
  defp do_timeout({:grace, seat_number}, state) do
    state = put_room(state, RoomState.expire_grace(state.room, seat_number))
    broadcast(state, "seat_sitting_out", %{seat: seat_number, reason: "disconnected"})
    announce(state)
    state
  end

  defp do_timeout({:rebuy, seat_number}, state) do
    seat = Map.fetch!(state.room.seats, seat_number)
    broadcast(state, "rebuy_expired", %{seat: seat_number, user_id: seat.user_id})
    state
  end

  defp do_timeout(:button_draw, state) do
    # Раздача стартует здесь (задача 4). Пока фиксируем результат розыгрыша.
    room = %{state.room | phase: :idle}
    state = put_room(state, room)
    broadcast(state, "button_ready", %{button_seat: room.button_seat})
    state
  end

  defp schedule(state, key, ms) do
    state = cancel_timer(state, key)
    ref = new_ref()

    timer =
      if state.timer_mode == :real do
        Process.send_after(self(), {:table_timeout, key, ref}, ms)
      end

    %{state | timers: Map.put(state.timers, key, {ref, timer})}
  end

  defp cancel_timer(state, key) do
    case Map.pop(state.timers, key) do
      {nil, timers} ->
        %{state | timers: timers}

      {{_ref, timer}, timers} ->
        if timer, do: Process.cancel_timer(timer)
        %{state | timers: timers}
    end
  end

  # Таймеры места живут ровно столько, сколько само место: ушедшему игроку
  # нечего ждать ни grace, ни ребая.
  defp cancel_timers_for_gone_seats(state) do
    occupied =
      state.room |> RoomState.seats() |> Enum.filter(&Seat.taken?/1) |> MapSet.new(& &1.number)

    state.timers
    |> Map.keys()
    |> Enum.filter(fn
      {kind, seat} when kind in [:grace, :rebuy] -> not MapSet.member?(occupied, seat)
      _key -> false
    end)
    |> Enum.reduce(state, &cancel_timer(&2, &1))
  end

  # --- игра ----------------------------------------------------------------

  # Розыгрыш кнопки проводится только при старте игры за столом: дальше
  # кнопка просто двигается по кругу от раздачи к раздаче (§5 задачи 3).
  defp maybe_start_game(%State{room: %RoomState{game_started?: true}} = state), do: state

  defp maybe_start_game(state) do
    seats = state.room |> RoomState.players() |> Enum.map(& &1.number) |> Enum.sort()

    if length(seats) >= 2 do
      start_button_draw(state, seats)
    else
      state
    end
  end

  defp start_button_draw(state, seats) do
    variant = VariantRegistry.fetch!(state.room.setting.game_type)
    {button_seat, drawn, rng} = ButtonDraw.draw(seats, variant, state.rng)

    room = %{
      state.room
      | button_seat: button_seat,
        big_blind_seat: big_blind_seat(button_seat, seats),
        game_started?: true,
        phase: :button_draw
    }

    state = %{state | room: room, rng: rng}
    animation_ms = state.room.setting.button_draw_animation_ms

    broadcast(state, "button_draw", %{
      cards: drawn,
      button_seat: button_seat,
      animation_ms: animation_ms
    })

    schedule(state, :button_draw, animation_ms)
  end

  # Игроков стало меньше двух — игра остановилась. Следующий сбор разыграет
  # кнопку заново, а не продолжит с прошлой.
  defp maybe_stop_game(state) do
    if length(RoomState.players(state.room)) < 2 do
      room = %{
        state.room
        | game_started?: false,
          button_seat: nil,
          big_blind_seat: nil,
          phase: :idle
      }

      state |> put_room(room) |> cancel_timer(:button_draw)
    else
      state
    end
  end

  defp big_blind_seat(button_seat, [_first, _second | _rest] = seats) when length(seats) == 2 do
    Enum.find(seats, &(&1 != button_seat))
  end

  defp big_blind_seat(button_seat, seats) do
    seats
    |> Stream.cycle()
    |> Stream.drop_while(&(&1 != button_seat))
    |> Enum.take(3)
    |> List.last()
  end

  # --- вспомогательное -----------------------------------------------------

  defp pick_seat(room, :first_free) do
    case RoomState.free_seats(room) do
      [] -> {:error, :no_seats_available}
      [seat | _rest] -> {:ok, seat}
    end
  end

  defp pick_seat(_room, seat) when is_integer(seat), do: {:ok, seat}
  defp pick_seat(_room, _seat), do: {:error, :invalid_seat}

  defp fetch_seat(room, user_id) do
    case RoomState.find_seat(room, user_id) do
      nil -> {:error, :not_seated}
      seat -> {:ok, seat}
    end
  end

  defp ensure_between_hands(%RoomState{phase: :hand}), do: {:error, :hand_in_progress}
  defp ensure_between_hands(_room), do: :ok

  defp reply_with(state, {:ok, room}) do
    state = put_room(state, room)
    announce(state)
    {:reply, :ok, state}
  end

  defp reply_with(state, {:error, reason}), do: {:reply, {:error, reason}, state}

  defp put_room(state, room), do: %{state | room: room}

  defp announce(state) do
    PubSub.broadcast(@pubsub, @rooms_topic, {:room_changed, RoomState.summary(state.room)})
  end

  defp broadcast(state, event, payload) do
    PubSub.broadcast(
      @pubsub,
      topic(state.room.room_id),
      {:table_event, event, Map.put(payload, :room_id, state.room.room_id)}
    )
  end

  defp new_ref, do: Ecto.UUID.generate()
end
