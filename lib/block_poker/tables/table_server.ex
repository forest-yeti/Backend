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

  alias BlockPoker.Engine.{ButtonDraw, Hand, HandStats, Preselect, Rng, Stats}
  alias BlockPoker.Engine.Variant.Registry, as: VariantRegistry
  alias BlockPoker.Tables.{RoomState, Seat, TableRegistry}
  alias Phoenix.PubSub

  @pubsub BlockPoker.PubSub
  @rooms_topic "tables:rooms"

  # Пауза между улицами при доводке борта и перед следующей раздачей.
  @runout_step_ms 1_500
  @next_hand_ms 2_500

  defmodule State do
    @moduledoc false
    @enforce_keys [:room, :game_mode, :timer_mode, :rng, :clock]
    defstruct [:room, :game_mode, :timer_mode, :rng, :clock, timers: %{}]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    GenServer.start_link(__MODULE__, opts, name: TableRegistry.via(room_id))
  end

  @spec topic(Ecto.UUID.t()) :: String.t()
  # Не "table:<id>": на топик с именем канала Phoenix подписывает канал сам,
  # и вторая явная подписка доставляла бы каждое событие дважды.
  def topic(room_id), do: "room_events:#{room_id}"

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
          pos_integer(),
          RoomState.profile()
        ) ::
          {:ok, %{reservation_id: String.t(), seat: pos_integer()}} | {:error, atom()}
  def reserve_seat(room, user_id, seat, buy_in, profile \\ %{}) do
    GenServer.call(room, {:reserve_seat, user_id, seat, buy_in, profile})
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

  @doc "Игровое действие. `seq` — счётчик стола, который клиент видел."
  @spec act(GenServer.server(), Ecto.UUID.t(), Hand.action(), non_neg_integer() | nil) ::
          :ok | {:error, atom()}
  def act(room, user_id, action, seq), do: GenServer.call(room, {:act, user_id, action, seq})

  @doc "Выбрать действие заранее (`nil` — снять выбор)."
  @spec preselect(GenServer.server(), Ecto.UUID.t(), Preselect.t() | nil) ::
          :ok | {:error, atom()}
  def preselect(room, user_id, choice), do: GenServer.call(room, {:preselect, user_id, choice})

  @doc "Сообщение в чат стола."
  @spec chat(GenServer.server(), Ecto.UUID.t(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def chat(room, user_id, text), do: GenServer.call(room, {:chat, user_id, text})

  @doc "Открыть свои карты по желанию."
  @spec show_cards(GenServer.server(), Ecto.UUID.t()) :: :ok | {:error, atom()}
  def show_cards(room, user_id), do: GenServer.call(room, {:show_cards, user_id})

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
      rng: Keyword.get_lazy(opts, :rng, &Rng.default/0),
      # Часы инжектируются: тайм-банк считает прошедшее время, и тесты
      # прогоняют его вручную, а не ожиданием (§11 CLAUDE.md).
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
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

  def handle_call({:reserve_seat, user_id, seat, buy_in, profile}, _from, state) do
    with {:ok, seat_number} <- pick_seat(state.room, seat),
         :ok <- RoomState.validate_buy_in(state.room, buy_in),
         reservation_id = new_ref(),
         {:ok, room} <-
           RoomState.reserve(state.room, seat_number, user_id, reservation_id, profile) do
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

        broadcast(state, "seat_taken", %{
          seat: seat.number,
          status: seat.status,
          user_id: seat.user_id,
          name: seat.name,
          avatar: seat.avatar
        })

        {:reply, {:ok, seat}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:act, user_id, action, seq}, _from, state) do
    with {:ok, hand} <- fetch_hand(state),
         {:ok, seat} <- seat_of(state, user_id),
         state = settle_time_bank(state, hand.to_act),
         {:ok, hand, events} <- Hand.act(hand, seat, action, seq) do
      {:reply, :ok, apply_hand(state, hand, events)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:preselect, user_id, choice}, _from, state) do
    case RoomState.set_preselect(state.room, user_id, choice) do
      {:ok, room, seat} ->
        state = put_room(state, room)

        # Выбор мог совпасть с уже наступившей очередью хода: игрок нажал
        # «фолд» ровно в тот момент, когда ход дошёл до него.
        {:reply, :ok, apply_pending_preselect(state, seat.number)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:chat, user_id, text}, _from, state) do
    case RoomState.push_chat(state.room, user_id, text, now_ms(state), DateTime.utc_now()) do
      {:ok, room, message} ->
        state = put_room(state, room)
        broadcast(state, "chat_message", message)
        {:reply, {:ok, message}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:show_cards, user_id}, _from, state) do
    with {:ok, hand} <- fetch_hand(state),
         {:ok, seat} <- seat_of(state, user_id),
         {:ok, hand, events} <- Hand.show_cards(hand, seat) do
      {:reply, :ok, apply_hand(state, hand, events)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:release_seat, reservation_id}, _from, state) do
    state = put_room(state, RoomState.release(state.room, reservation_id))
    announce(state)
    {:reply, :ok, state}
  end

  def handle_call({:begin_leave, user_id}, _from, state) do
    ref = new_ref()

    # Право встать проверяется **здесь**, внутри процесса, а не вызывающим
    # по снятому снапшоту: между «посмотрел состояние» и «встал» комната
    # успевает начать раздачу, и проверка снаружи её не увидит.
    case ensure_can_leave(state, user_id) do
      :ok -> do_begin_leave(state, user_id, ref)
      {:error, reason} -> {:reply, {:error, reason}, state}
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
    with {:ok, seat} <- fetch_active_seat(state.room, user_id),
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

  defp ensure_can_leave(state, user_id) do
    case RoomState.find_seat(state.room, user_id) do
      nil ->
        {:error, :not_seated}

      %Seat{status: :leaving} ->
        {:error, :leave_in_progress}

      seat ->
        if state.game_mode.can_leave?(state.room, seat),
          do: :ok,
          else: {:error, :hand_in_progress}
    end
  end

  defp do_begin_leave(state, user_id, ref) do
    case RoomState.begin_leave(state.room, user_id, ref) do
      {:ok, room, stack} ->
        {:reply, {:ok, %{ref: ref, stack: stack}}, put_room(state, room)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

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
    room = %{state.room | phase: :idle, button_draw: nil}
    state = put_room(state, room)
    broadcast(state, "button_ready", %{button_seat: room.button_seat})
    start_hand(state)
  end

  # Время на ход вышло: ход делается за игрока — чек, если бесплатно, иначе
  # фолд. Молча зависнуть стол не может.
  defp do_timeout(:action, state) do
    case fetch_hand(state) do
      {:ok, hand} -> action_timeout(state, hand, seat_to_act(state, hand))
      {:error, _reason} -> state
    end
  end

  # Пауза между раздачами: игрок должен успеть увидеть, чем всё кончилось.
  defp do_timeout(:next_hand, state), do: start_hand(state)

  # Доводка борта при олл-ине: по улице за тик, чтобы игрок успел увидеть
  # флоп, тёрн и ривер, а не только итог.
  defp do_timeout(:runout, state) do
    case fetch_hand(state) do
      {:ok, hand} ->
        case Hand.deal_next(hand) do
          {:ok, hand, events} -> apply_hand(state, hand, events)
          {:error, _reason} -> state
        end

      {:error, _reason} ->
        state
    end
  end

  defp action_timeout(state, hand, %Seat{time_bank: bank} = seat)
       when bank > 0 do
    if state.room.time_bank_at == nil do
      start_time_bank(state, hand, seat)
    else
      # Банк догорел до конца: обнуляем остаток и ходим за игрока.
      state
      |> put_room(RoomState.drain_time_bank(state.room, seat.number))
      |> force_action(hand)
    end
  end

  defp action_timeout(state, hand, seat) do
    state |> settle_time_bank(seat && seat.number) |> force_action(hand)
  end

  defp force_action(state, hand) do
    case Hand.timeout(hand) do
      {:ok, hand, events} -> apply_hand(state, hand, events)
      {:error, _reason} -> state
    end
  end

  defp seat_to_act(_state, %Hand{to_act: nil}), do: nil
  defp seat_to_act(state, hand), do: Map.get(state.room.seats, hand.to_act)

  # --- раздача --------------------------------------------------------------

  defp start_hand(%State{room: %RoomState{phase: :hand}} = state), do: state

  defp start_hand(state), do: start_hand(state, length(in_game_seats(state.room)))

  # `attempts` — по одному обороту блайндов на каждое занятое место: если за
  # столом одни ждущие BB, блайнд обязан до кого-то из них дойти, но круг
  # должен быть конечным.
  defp start_hand(state, attempts) when attempts <= 0, do: state

  defp start_hand(state, attempts) do
    state = put_room(state, activate_big_blind(state.room))

    case state.game_mode.hand_setup(state.room) do
      {:ok, setup} ->
        {hand, events} = Hand.start(setup, state.rng, rake: rake_fun(state))

        state =
          put_room(state, %{
            state.room
            | phase: :hand,
              hand: hand,
              hand_stats: HandStats.new(hand),
              showdown: nil
          })

        broadcast(state, "hand_started", %{
          button_seat: setup.button_seat,
          players: seat_stacks(hand)
        })

        apply_hand(state, hand, events)

      {:error, :not_enough_players} ->
        # Игроков за столом хватает, но они ждут блайнда — двигаем блайнды
        # дальше по кругу, пока большой не дойдёт до кого-то из ждущих.
        if length(in_game_seats(state.room)) >= 2 do
          state |> put_room(rotate_blinds(state.room)) |> start_hand(attempts - 1)
        else
          state
        end

      {:error, _reason} ->
        state
    end
  end

  defp rotate_blinds(room) do
    room = %{room | button_seat: next_button(room)}
    %{room | big_blind_seat: big_blind_seat_for(room)}
  end

  # Игрок, ждавший большого блайнда, вступает ровно тогда, когда блайнд
  # доходит до него: иначе вход был бы способом не платить блайнды.
  defp activate_big_blind(%RoomState{big_blind_seat: nil} = room), do: room

  defp activate_big_blind(room) do
    case Map.get(room.seats, room.big_blind_seat) do
      %Seat{waiting_for_bb: true} = seat ->
        %{room | seats: Map.put(room.seats, seat.number, %{seat | waiting_for_bb: false})}

      _other ->
        room
    end
  end

  defp rake_fun(state) do
    setting = state.room.setting
    fn pot, players, opts -> state.game_mode.rake(setting, pot, players, opts) end
  end

  # Пока раздача идёт, источник правды по стекам — она: комната только
  # зеркалит их, чтобы снапшот и лобби не разъезжались с движком.
  defp apply_hand(state, hand, events) do
    room = %{state.room | hand: hand, hand_stats: track_stats(state.room.hand_stats, events)}
    state = put_room(state, sync_seats(room, hand))
    state = Enum.reduce(events, state, &emit/2)
    state = clear_preselects_on_new_street(state, events)

    cond do
      Hand.finished?(hand) -> finish_hand(state, hand)
      hand.runout? -> schedule(cancel_timer(state, :action), :runout, @runout_step_ms)
      true -> advance_to_actor(state, hand)
    end
  end

  # Новая улица — новая обстановка: выбор, сделанный до флопа, к ней уже
  # не относится, и молча применять его нельзя.
  defp clear_preselects_on_new_street(state, events) do
    if Enum.any?(events, &match?({:street_dealt, _payload}, &1)) do
      put_room(state, RoomState.clear_preselects(state.room))
    else
      state
    end
  end

  # Очередь дошла до игрока: либо за него ходит его же заранее выбранное
  # действие, либо стол ждёт и включает таймер.
  defp advance_to_actor(state, hand) do
    seat = seat_to_act(state, hand)

    case preselect_decision(hand, seat) do
      {:act, action} ->
        apply_preselected(state, hand, seat, action)

      :cancel ->
        state
        |> drop_preselect(seat, "action_changed")
        |> arm_action_timer(hand)

      _none ->
        arm_action_timer(state, hand)
    end
  end

  defp preselect_decision(_hand, nil), do: :none

  defp preselect_decision(hand, seat) do
    Preselect.resolve(seat.preselect, Hand.legal_actions(hand, seat.number))
  end

  defp apply_preselected(state, hand, seat, action) do
    state = put_room(state, RoomState.clear_preselect(state.room, seat.number))
    private(state, seat.user_id, "preselect_applied", %{seat: seat.number, action: action})

    case Hand.act(hand, seat.number, action, nil) do
      {:ok, hand, events} -> apply_hand(state, hand, events)
      # Выбор не подошёл к обстановке — решает игрок, а не стол.
      {:error, _reason} -> arm_action_timer(state, hand)
    end
  end

  defp drop_preselect(state, seat, reason) do
    state = put_room(state, RoomState.clear_preselect(state.room, seat.number))
    private(state, seat.user_id, "preselect_cleared", %{seat: seat.number, reason: reason})
    state
  end

  # Выбор сделан ровно в тот момент, когда очередь уже дошла до игрока.
  defp apply_pending_preselect(state, seat_number) do
    with {:ok, hand} <- fetch_hand(state),
         true <- hand.to_act == seat_number,
         seat = Map.get(state.room.seats, seat_number),
         {:act, action} <- preselect_decision(hand, seat) do
      state
      |> settle_time_bank(seat_number)
      |> apply_preselected(hand, seat, action)
    else
      _other -> state
    end
  end

  defp sync_seats(room, hand) do
    seats =
      Enum.reduce(hand.players, room.seats, fn {number, player}, seats ->
        Map.update!(seats, number, &%{&1 | stack: player.stack})
      end)

    %{room | seats: seats, action_seq: hand.seq}
  end

  defp arm_action_timer(state, %Hand{to_act: nil} = _hand), do: cancel_timer(state, :action)

  defp arm_action_timer(state, hand) do
    ms = state.room.setting.action_timeout_ms
    deadline = now_ms(state) + ms
    state = put_room(state, %{state.room | deadline_at: deadline, time_bank_at: nil})
    broadcast(state, "action_prompt", prompt_payload(state, hand, ms))
    schedule(state, :action, ms)
  end

  # Обычное время кончилось. Банк не пуст — игрок продолжает думать за свой
  # счёт; пуст — стол ходит за него. Ход не делается «на всякий случай»:
  # это и есть смысл банка.
  defp start_time_bank(state, hand, seat) do
    state = put_room(state, RoomState.start_time_bank(state.room, now_ms(state)))
    deadline = now_ms(state) + seat.time_bank
    state = put_room(state, %{state.room | deadline_at: deadline})

    broadcast(state, "time_bank_started", %{
      seat: seat.number,
      action_seq: hand.seq,
      time_bank_ms: seat.time_bank,
      deadline_ms: seat.time_bank
    })

    schedule(state, :action, seat.time_bank)
  end

  defp settle_time_bank(state, seat_number) do
    put_room(state, RoomState.settle_time_bank(state.room, seat_number, now_ms(state)))
  end

  defp now_ms(%State{clock: clock}), do: clock.()

  defp finish_hand(state, hand) do
    state = state |> cancel_timer(:action) |> cancel_timer(:runout)

    state = record_stats(state, hand)

    room =
      %{
        state.room
        | hand: nil,
          hand_stats: nil,
          deadline_at: nil,
          time_bank_at: nil,
          showdown: nil
      }
      |> RoomState.clear_preselects()
      |> RoomState.refill_time_banks(owners_of(hand))

    room = state.game_mode.on_hand_finished(room, hand.results)
    room = %{room | button_seat: next_button(room)}
    room = %{room | big_blind_seat: big_blind_seat_for(room)}

    state =
      state
      |> put_room(room)
      |> handle_broke_players(hand)
      |> maybe_stop_game()

    announce(state)

    if length(RoomState.players(state.room)) >= 2 and state.room.game_started? do
      schedule(state, :next_hand, @next_hand_ms)
    else
      state
    end
  end

  defp track_stats(hand_stats, events),
    do: Enum.reduce(events, hand_stats, &HandStats.track(&2, &1))

  # Показатели сессии обновляются раз в раздачу, и ровно тогда же уходят
  # клиенту: между раздачами меняться им не от чего.
  defp record_stats(state, hand) do
    owners = owners_of(hand)
    deltas = HandStats.finish(state.room.hand_stats, hand)
    state = put_room(state, RoomState.record_stats(state.room, deltas, owners))
    broadcast(state, "stats_update", %{seats: stats_payload(state.room)})
    state
  end

  # Кто сидел на месте, когда раздача начиналась. Нужен и показателям, и
  # пополнению банка: место могло освободиться, и достаться они должны
  # тому, кто играл, а не тому, кто сел следом.
  defp owners_of(hand), do: Map.new(hand.players, fn {seat, player} -> {seat, player.id} end)

  defp stats_payload(room) do
    room
    |> RoomState.seats()
    |> Enum.filter(&Seat.occupied?/1)
    |> Map.new(&{&1.number, Stats.summary(&1.stats)})
  end

  # Проигравший всё не встаёт молча: кэш даёт ему время докупиться.
  defp handle_broke_players(state, hand) do
    Enum.reduce(hand.players, state, fn {number, _player}, acc ->
      seat = Map.get(acc.room.seats, number)

      if seat != nil and seat.stack == 0 and Seat.occupied?(seat) do
        acc
        |> put_room(acc.game_mode.on_zero_stack(acc.room, seat))
        |> schedule({:rebuy, number}, acc.room.setting.rebuy_prompt_ms)
      else
        acc
      end
    end)
  end

  defp next_button(room) do
    case in_game_seats(room) do
      [] ->
        room.button_seat

      seats ->
        # Именно поиск с запасным значением, а не бесконечный `Stream.cycle`:
        # когда кнопка стоит на старшем месте, отбрасывать «меньшие или
        # равные» пришлось бы вечно, и процесс стола вставал колом.
        current = room.button_seat || 0
        Enum.find(seats, hd(seats), &(&1 > current))
    end
  end

  defp big_blind_seat_for(room) do
    case in_game_seats(room) do
      [] -> nil
      seats -> big_blind_seat(room.button_seat, seats)
    end
  end

  defp in_game_seats(room) do
    room |> RoomState.players() |> Enum.map(& &1.number) |> Enum.sort()
  end

  defp seat_stacks(hand) do
    Enum.map(hand.players, fn {seat, player} -> %{seat: seat, stack: player.stack} end)
  end

  defp prompt_payload(state, hand, ms) do
    seat = seat_to_act(state, hand)

    %{
      seat: hand.to_act,
      action_seq: hand.seq,
      deadline_ms: ms,
      # Запас показывается вместе с подсказкой: игрок должен видеть, сколько
      # у него есть сверху, **до** того, как обычное время кончится.
      time_bank_ms: (seat && seat.time_bank) || 0,
      legal_actions: Hand.legal_actions(hand, hand.to_act)
    }
  end

  defp fetch_hand(%State{room: %RoomState{hand: nil}}), do: {:error, :no_hand}
  defp fetch_hand(%State{room: %RoomState{hand: hand}}), do: {:ok, hand}

  defp seat_of(state, user_id) do
    case RoomState.find_seat(state.room, user_id) do
      nil -> {:error, :not_seated}
      seat -> {:ok, seat.number}
    end
  end

  # Карманные карты уходят адресно: их получает только владелец места.
  defp emit({:hole_dealt, by_seat}, state) do
    Enum.reduce(by_seat, state, fn {seat_number, cards}, acc ->
      case Map.get(acc.room.seats, seat_number) do
        nil -> acc
        seat -> private(acc, seat.user_id, "your_cards", %{seat: seat_number, cards: cards})
      end
    end)
  end

  # Подсказка о ходе уходит из `arm_action_timer`: только там известен дедлайн.
  defp emit({:action_prompt, _payload}, state), do: state

  # Открытые карты и шансы держим в состоянии комнаты: подключившийся
  # в середине доводки увидит их в снапшоте, а не пустой стол.
  defp emit({:all_in_showdown, payload}, state) do
    state = put_room(state, %{state.room | showdown: payload})
    broadcast(state, "all_in_showdown", payload)
    state
  end

  defp emit({:equity_update, equity}, state) do
    showdown = Map.put(state.room.showdown || %{}, :equity, equity)
    state = put_room(state, %{state.room | showdown: showdown})
    broadcast(state, "equity_update", %{equity: equity})
    state
  end

  defp emit({event, payload}, state) do
    broadcast(state, Atom.to_string(event), payload)
    state
  end

  defp private(state, user_id, event, payload) do
    PubSub.broadcast(
      @pubsub,
      topic(state.room.room_id),
      {:table_private, user_id, event, Map.put(payload, :room_id, state.room.room_id)}
    )

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
  # Кнопка разыграна один раз за стол, а раздач за ним — много. Если игра
  # уже начата и раздача сейчас не идёт, сажать нового игрока значит начать
  # следующую руку: иначе стол молча стоит с полным составом.
  defp maybe_start_game(%State{room: %RoomState{game_started?: true, hand: nil}} = state) do
    start_hand(state)
  end

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

    animation_ms = state.room.setting.button_draw_animation_ms

    room = %{
      state.room
      | button_seat: button_seat,
        big_blind_seat: big_blind_seat(button_seat, seats),
        game_started?: true,
        phase: :button_draw,
        button_draw: %{
          cards: drawn,
          button_seat: button_seat,
          ends_at: System.monotonic_time(:millisecond) + animation_ms
        }
    }

    state = %{state | room: room, rng: rng}

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
          button_draw: nil,
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

  # Место, с которого игрок уже встаёт, заморожено: докупленные в это окно
  # фишки исчезли бы вместе с местом, а деньги из кошелька уже ушли.
  defp fetch_active_seat(room, user_id) do
    case fetch_seat(room, user_id) do
      {:ok, %Seat{status: :leaving}} -> {:error, :leave_in_progress}
      other -> other
    end
  end

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
