defmodule BlockPoker.Tables.RoomState do
  @moduledoc """
  Состояние комнаты как **данные и чистые функции над ними**.

  `TableServer` — оболочка: он владеет этим состоянием, ходит в кошелёк и
  заводит таймеры. Всё, что можно посчитать без процессов, посчитано здесь,
  поэтому правила посадки тестируются без `start_supervised!` и без БД.

  Настройки шаблона комната **копирует себе при запуске** и больше за ними
  не ходит (§8 задачи 3): правка лимита в БД не должна пересаживать игрока
  с 0.1/0.2 на 1/2 посреди сессии.
  """

  alias BlockPoker.CashGames.CashGameSetting
  alias BlockPoker.Chat
  alias BlockPoker.Engine.{EntryRules, Preselect, Stats, TimeBank}
  alias BlockPoker.Tables.Seat

  @type phase :: :idle | :button_draw | :hand
  @type entry :: :wait_bb | :post

  @typedoc "Снимок профиля игрока: то, чем стол его показывает."
  @type profile :: %{optional(:name) => String.t(), optional(:avatar) => String.t()}

  @type t :: %__MODULE__{
          room_id: Ecto.UUID.t(),
          setting: CashGameSetting.t(),
          seats: %{pos_integer() => Seat.t()},
          phase: phase(),
          draining?: boolean(),
          button_seat: pos_integer() | nil,
          big_blind_seat: pos_integer() | nil,
          hands_played: non_neg_integer(),
          game_started?: boolean(),
          action_seq: non_neg_integer(),
          recent_leavers: %{Ecto.UUID.t() => non_neg_integer()},
          button_draw: button_draw() | nil,
          hand: term() | nil,
          hand_stats: term() | nil,
          time_bank_at: integer() | nil,
          chat: [Chat.message()],
          deadline_at: integer() | nil,
          showdown: map() | nil
        }

  @typedoc """
  Идущий розыгрыш кнопки. Хранится в состоянии, а не только в событии:
  игрок, посаженный через `quick_seat`, подключается к столу уже после
  старта розыгрыша и иначе не увидел бы карт — а смысл процедуры в том,
  чтобы он видел, что позиция досталась не по решению сервера.
  """
  @type button_draw :: %{
          cards: [map()],
          button_seat: pos_integer(),
          ends_at: integer()
        }

  @enforce_keys [:room_id, :setting, :seats]
  defstruct [
    :room_id,
    :setting,
    :seats,
    :button_seat,
    :big_blind_seat,
    phase: :idle,
    draining?: false,
    game_started?: false,
    hands_played: 0,
    action_seq: 0,
    recent_leavers: %{},
    button_draw: nil,
    # Идущая раздача (`Engine.Hand`) и дедлайн текущего хода в монотонных мс.
    hand: nil,
    # Счётчик показателей идущей раздачи (`Engine.HandStats`): по её концу
    # прибавка расходится по местам и обнуляется.
    hand_stats: nil,
    # Момент включения тайм-банка на текущем решении (монотонные мс) либо
    # `nil`, если игрок думает в пределах обычного времени.
    time_bank_at: nil,
    chat: [],
    deadline_at: nil,
    # Открытые при олл-ине карты и шансы: игрок, подключившийся в середине
    # доводки, должен видеть то же, что и остальные.
    showdown: nil
  ]

  @spec new(Ecto.UUID.t(), CashGameSetting.t()) :: t()
  def new(room_id, %CashGameSetting{} = setting) do
    seats = Map.new(1..setting.max_players, fn number -> {number, Seat.new(number)} end)
    %__MODULE__{room_id: room_id, setting: setting, seats: seats}
  end

  @spec seats(t()) :: [Seat.t()]
  def seats(%__MODULE__{seats: seats}), do: seats |> Map.values() |> Enum.sort_by(& &1.number)

  @spec seats_taken(t()) :: non_neg_integer()
  def seats_taken(state), do: state |> seats() |> Enum.count(&Seat.taken?/1)

  @spec players(t()) :: [Seat.t()]
  def players(state), do: state |> seats() |> Enum.filter(&Seat.occupied?/1)

  @spec free_seats(t()) :: [pos_integer()]
  def free_seats(state),
    do: state |> seats() |> Enum.filter(&Seat.empty?/1) |> Enum.map(& &1.number)

  @spec full?(t()) :: boolean()
  def full?(state), do: free_seats(state) == []

  @spec empty?(t()) :: boolean()
  def empty?(state), do: seats_taken(state) == 0

  @spec heads_up?(t()) :: boolean()
  def heads_up?(%__MODULE__{setting: setting}), do: setting.max_players == 2

  @spec find_seat(t(), Ecto.UUID.t()) :: Seat.t() | nil
  def find_seat(state, user_id) do
    state |> seats() |> Enum.find(&(&1.user_id == user_id))
  end

  @doc """
  Выбрать действие заранее. Пустой выбор снимает предыдущий.
  """
  @spec set_preselect(t(), Ecto.UUID.t(), Preselect.t() | nil) ::
          {:ok, t(), Seat.t()} | {:error, atom()}
  def set_preselect(%__MODULE__{} = state, user_id, choice) do
    with {:ok, seat} <- fetch_player(state, user_id) do
      seat = %{seat | preselect: choice}
      {:ok, put_seat(state, seat), seat}
    end
  end

  @doc "Снять выбор одного места."
  @spec clear_preselect(t(), pos_integer()) :: t()
  def clear_preselect(%__MODULE__{} = state, seat_number) do
    case Map.get(state.seats, seat_number) do
      nil -> state
      seat -> put_seat(state, %{seat | preselect: nil})
    end
  end

  @doc """
  Снять выбор у всех: новая улица или новая раздача — новая обстановка,
  и выбор, сделанный в прошлой, к ней не относится.
  """
  @spec clear_preselects(t()) :: t()
  def clear_preselects(%__MODULE__{} = state) do
    seats = Map.new(state.seats, fn {number, seat} -> {number, %{seat | preselect: nil}} end)
    %{state | seats: seats}
  end

  @doc "Включить тайм-банк на текущем решении."
  @spec start_time_bank(t(), integer()) :: t()
  def start_time_bank(%__MODULE__{} = state, now), do: %{state | time_bank_at: now}

  @doc """
  Списать с банка прошедшее время и выключить его.

  Списывается ровно продуманное сверх обычного времени: банк включается
  только после того, как обычное кончилось.
  """
  @spec settle_time_bank(t(), pos_integer() | nil, integer()) :: t()
  def settle_time_bank(%__MODULE__{time_bank_at: nil} = state, _seat_number, _now), do: state

  def settle_time_bank(%__MODULE__{} = state, seat_number, now) do
    elapsed = now - state.time_bank_at
    state = %{state | time_bank_at: nil}

    case Map.get(state.seats, seat_number) do
      nil -> state
      seat -> put_seat(state, %{seat | time_bank: TimeBank.spend(seat.time_bank, elapsed)})
    end
  end

  @doc """
  Банк догорел до конца: остаток обнуляется, а не досчитывается по часам.

  Это не оптимизация: таймер срабатывает ровно тогда, когда запас кончился,
  и любые миллисекунды, оставшиеся от расхождения часов с таймером, — мусор,
  из-за которого банк «включался» бы ещё раз на пустом месте.
  """
  @spec drain_time_bank(t(), pos_integer() | nil) :: t()
  def drain_time_bank(%__MODULE__{} = state, nil), do: %{state | time_bank_at: nil}

  def drain_time_bank(%__MODULE__{} = state, seat_number) do
    state = %{state | time_bank_at: nil}

    case Map.get(state.seats, seat_number) do
      nil -> state
      seat -> put_seat(state, %{seat | time_bank: 0})
    end
  end

  @doc "Пополнить банки сыгравшим раздачу — до потолка шаблона."
  @spec refill_time_banks(t(), [pos_integer()]) :: t()
  def refill_time_banks(%__MODULE__{} = state, seat_numbers) do
    amount = state.setting.time_bank_refill
    max = state.setting.time_bank_ms

    Enum.reduce(seat_numbers, state, fn number, acc ->
      case Map.get(acc.seats, number) do
        nil -> acc
        seat -> put_seat(acc, %{seat | time_bank: TimeBank.refill(seat.time_bank, amount, max)})
      end
    end)
  end

  @doc """
  Сообщение в чат: проверка частоты и запись в историю комнаты.

  Писать может только сидящий за столом: наблюдателя стол не знает по имени
  и не отвечает за него. Читать чат при этом может кто угодно.
  """
  @spec push_chat(t(), Ecto.UUID.t(), String.t(), integer(), DateTime.t()) ::
          {:ok, t(), Chat.message()} | {:error, atom()}
  def push_chat(%__MODULE__{} = state, user_id, text, now, at) do
    with {:ok, seat} <- fetch_player(state, user_id),
         {:ok, sanitized} <- Chat.sanitize(text),
         {:ok, sent_at} <- Chat.throttle(seat.chat_sent_at, now) do
      message = %{seat: seat.number, user_id: user_id, name: seat.name, text: sanitized, at: at}
      state = put_seat(state, %{seat | chat_sent_at: sent_at})
      {:ok, %{state | chat: Chat.push(state.chat, message)}, message}
    end
  end

  @doc """
  Разнести показатели сыгранной раздачи по местам.

  `owners` — кто сидел на месте, когда раздача начиналась. Сверка обязательна:
  игрок с нулевым стеком вправе встать посреди раздачи, и к её концу за
  местом может сидеть уже другой человек. Чужие показатели ему не достаются.
  """
  @spec record_stats(t(), %{pos_integer() => Stats.t()}, %{pos_integer() => Ecto.UUID.t()}) :: t()
  def record_stats(%__MODULE__{} = state, deltas, owners) do
    seats =
      Enum.reduce(deltas, state.seats, fn {number, delta}, seats ->
        seat = Map.get(seats, number)

        if seat != nil and seat.user_id != nil and seat.user_id == Map.get(owners, number) do
          Map.put(seats, number, %{seat | stats: Stats.merge(seat.stats, delta)})
        else
          seats
        end
      end)

    %{state | seats: seats}
  end

  @doc "Фишки, лежащие в комнате. Основа инварианта денег (§4 задачи 3)."
  @spec chips_in_play(t()) :: non_neg_integer()
  def chips_in_play(state) do
    state |> seats() |> Enum.reduce(0, fn seat, acc -> acc + seat.stack end)
  end

  @doc """
  Резерв места: первый шаг посадки. Место помечается за игроком **до** похода
  в кошелёк, иначе за время транзакции его успеет занять другой.
  """
  @spec reserve(t(), pos_integer(), Ecto.UUID.t(), String.t(), profile()) ::
          {:ok, t()} | {:error, atom()}
  def reserve(state, seat_number, user_id, reservation_id, profile \\ %{}) do
    with :ok <- ensure_open(state),
         {:ok, seat} <- fetch_seat(state, seat_number),
         :ok <- ensure_free(seat),
         :ok <- ensure_not_seated(state, user_id) do
      seat = %{
        seat
        | status: :reserved,
          user_id: user_id,
          reservation_id: reservation_id,
          name: Map.get(profile, :name),
          avatar: Map.get(profile, :avatar)
      }

      {:ok, put_seat(state, seat)}
    end
  end

  @doc "Снятие резерва: бай-ин не прошёл, место должно вернуться свободным."
  @spec release(t(), String.t()) :: t()
  def release(state, reservation_id) do
    case Enum.find(seats(state), &(&1.reservation_id == reservation_id)) do
      nil -> state
      seat -> put_seat(state, Seat.free(seat))
    end
  end

  @doc """
  Подтверждение посадки: фишки уже списаны с кошелька, место становится
  занятым. Здесь же решается, вступает игрок сразу или ждёт блайнда.
  """
  @spec confirm(t(), String.t(), non_neg_integer(), entry()) ::
          {:ok, t(), Seat.t()} | {:error, atom()}
  def confirm(state, reservation_id, amount, intent) do
    case Enum.find(seats(state), &(&1.reservation_id == reservation_id)) do
      nil ->
        {:error, :reservation_lost}

      seat ->
        decision = entry_decision(state, seat, intent)

        seat = %{
          seat
          | status: :playing,
            stack: amount,
            reservation_id: nil,
            time_bank: TimeBank.initial(state.setting.time_bank_ms),
            waiting_for_bb: decision.status == :waiting_for_bb,
            post_required: decision.status == :post_required,
            can_post: decision.can_post
        }

        {:ok, put_seat(state, seat), seat}
    end
  end

  @doc """
  Решение о вступлении в игру. Всё, что для него нужно, комната знает сама:
  расклад мест, кнопку и историю ухода игрока.
  """
  @spec entry_decision(t(), Seat.t(), entry()) :: EntryRules.decision()
  def entry_decision(state, seat, intent) do
    EntryRules.decide(%{
      seat: seat.number,
      intent: intent,
      seats_in_game: state |> players() |> Enum.map(& &1.number),
      button_seat: state.button_seat,
      big_blind_seat: state.big_blind_seat,
      big_blind: state.setting.big_blind,
      heads_up?: heads_up?(state),
      allow_post_blind?: state.setting.allow_post_blind,
      missed_blinds: seat.missed_blinds,
      dodging?: dodging?(state, seat.user_id)
    })
  end

  @doc """
  Границы бай-ина в фишках с учётом уже лежащего перед игроком стека:
  докупка не может поднять стек выше `max_buy_in`.
  """
  @spec validate_buy_in(t(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, :invalid_buy_in}
  def validate_buy_in(state, amount, current_stack \\ 0) do
    min = CashGameSetting.min_buy_in_chips(state.setting)
    max = CashGameSetting.max_buy_in_chips(state.setting)

    cond do
      not (is_integer(amount) and amount > 0) -> {:error, :invalid_buy_in}
      current_stack == 0 and amount < min -> {:error, :invalid_buy_in}
      max != nil and current_stack + amount > max -> {:error, :invalid_buy_in}
      true -> :ok
    end
  end

  @doc "Докупка. Разрешена между раздачами в любой момент, до `max_buy_in`."
  @spec add_chips(t(), Ecto.UUID.t(), non_neg_integer()) ::
          {:ok, t(), Seat.t()} | {:error, atom()}
  def add_chips(state, user_id, amount) do
    with {:ok, seat} <- fetch_player(state, user_id),
         :ok <- ensure_between_hands(state),
         :ok <- validate_buy_in(state, amount, seat.stack) do
      seat = %{seat | stack: seat.stack + amount}

      seat =
        if seat.stack > 0 and seat.status == :sitting_out,
          do: activate_seat(seat, state),
          else: seat

      {:ok, put_seat(state, seat), seat}
    end
  end

  @doc """
  Начало ухода из-за стола: стек снимается со стола и уходит «в полёт»
  к кошельку, место остаётся занятым до подтверждения транзакции.

  Порядок именно такой, потому что обратный — сначала освободить место,
  потом переводить деньги — оставляет фишки без владельца, если перевод упал.
  """
  @spec begin_leave(t(), Ecto.UUID.t(), String.t()) ::
          {:ok, t(), non_neg_integer()} | {:error, atom()}
  def begin_leave(state, user_id, ref) do
    with {:ok, seat} <- fetch_player(state, user_id) do
      stack = seat.stack
      seat = %{seat | status: :leaving, stack: 0, reservation_id: ref}
      {:ok, put_seat(state, seat), stack}
    end
  end

  @doc "Cash-out прошёл: место свободно."
  @spec finish_leave(t(), String.t()) :: t()
  def finish_leave(state, ref) do
    case Enum.find(seats(state), &(&1.reservation_id == ref)) do
      nil -> state
      seat -> state |> put_seat(Seat.free(seat)) |> remember_leaver(seat.user_id)
    end
  end

  @doc "Cash-out не прошёл: фишки возвращаются на место, игрок остаётся сидеть."
  @spec cancel_leave(t(), String.t(), non_neg_integer()) :: t()
  def cancel_leave(state, ref, stack) do
    case Enum.find(seats(state), &(&1.reservation_id == ref)) do
      nil ->
        state

      seat ->
        put_seat(state, %{seat | status: :sitting_out, stack: stack, reservation_id: nil})
    end
  end

  @spec sit_out(t(), Ecto.UUID.t()) :: {:ok, t()} | {:error, atom()}
  def sit_out(state, user_id) do
    with {:ok, seat} <- fetch_player(state, user_id) do
      {:ok, put_seat(state, %{seat | status: :sitting_out, waiting_for_bb: false})}
    end
  end

  @spec sit_in(t(), Ecto.UUID.t()) :: {:ok, t()} | {:error, atom()}
  def sit_in(state, user_id) do
    with {:ok, seat} <- fetch_player(state, user_id) do
      if seat.stack == 0 do
        {:error, :zero_stack}
      else
        {:ok, put_seat(state, activate_seat(seat, state))}
      end
    end
  end

  @doc "Разрыв связи: место держится, игрок помечается отключённым."
  @spec disconnect(t(), Ecto.UUID.t()) :: {:ok, t()} | {:error, atom()}
  def disconnect(state, user_id) do
    with {:ok, seat} <- fetch_player(state, user_id) do
      {:ok, put_seat(state, %{seat | status: :disconnected})}
    end
  end

  @doc "Возврат внутри grace-периода: игрок продолжает с того же места."
  @spec reconnect(t(), Ecto.UUID.t()) :: {:ok, t(), Seat.t()} | {:error, atom()}
  def reconnect(state, user_id) do
    with {:ok, seat} <- fetch_player(state, user_id) do
      status = if seat.stack > 0, do: :playing, else: :sitting_out
      seat = %{seat | status: status}
      {:ok, put_seat(state, seat), seat}
    end
  end

  @doc """
  Grace-период истёк: место остаётся за игроком, но раздачи он пропускает.
  Освобождение места — отдельное решение по `sit_out_max_hands`, и принимает
  его не таймер обрыва связи.
  """
  @spec expire_grace(t(), pos_integer()) :: t()
  def expire_grace(state, seat_number) do
    case Map.fetch(state.seats, seat_number) do
      {:ok, %Seat{status: :disconnected} = seat} ->
        put_seat(state, %{seat | status: :sitting_out, waiting_for_bb: false})

      _other ->
        state
    end
  end

  @doc """
  Стек обнулился: место не освобождается, игрок уходит в `sitting_out` и
  получает окно на докупку. С нулевым стеком играть нельзя, а держать стол
  ожиданием его решения недопустимо.
  """
  @spec zero_stack(t(), pos_integer()) :: t()
  def zero_stack(state, seat_number) do
    case Map.fetch(state.seats, seat_number) do
      {:ok, seat} -> put_seat(state, %{seat | status: :sitting_out, waiting_for_bb: false})
      :error -> state
    end
  end

  @spec mark_draining(t()) :: t()
  def mark_draining(state), do: %{state | draining?: true}

  @doc """
  Можно ли закрыть комнату прямо сейчас: пуста, не идёт раздача и в ней
  не осталось фишек, не вернувшихся в кошельки.
  """
  @spec closable?(t()) :: boolean()
  def closable?(state) do
    empty?(state) and state.phase == :idle and chips_in_play(state) == 0
  end

  @doc "Сводка для лобби. Ничего приватного здесь нет и быть не может."
  @spec summary(t()) :: map()
  def summary(state) do
    %{
      room_id: state.room_id,
      setting_id: state.setting.id,
      seats_taken: seats_taken(state),
      max_players: state.setting.max_players,
      phase: state.phase,
      draining?: state.draining?
    }
  end

  @spec bump_seq(t()) :: t()
  def bump_seq(state), do: %{state | action_seq: state.action_seq + 1}

  # Встал и сел обратно в ту же комнату внутри окна — право «ждать блайнда»
  # потеряно, иначе вся конструкция обходится циклом «встал — сел».
  defp dodging?(_state, nil), do: false

  defp dodging?(state, user_id) do
    case Map.fetch(state.recent_leavers, user_id) do
      {:ok, hands} -> state.hands_played - hands < state.setting.blind_dodge_window_hands
      :error -> false
    end
  end

  defp remember_leaver(state, user_id) do
    %{state | recent_leavers: Map.put(state.recent_leavers, user_id, state.hands_played)}
  end

  defp activate_seat(%Seat{} = seat, state) do
    decision = entry_decision(state, seat, :wait_bb)

    %{
      seat
      | status: :playing,
        hands_sat_out: 0,
        waiting_for_bb: decision.status == :waiting_for_bb,
        post_required: decision.status == :post_required,
        can_post: decision.can_post
    }
  end

  defp put_seat(state, seat), do: %{state | seats: Map.put(state.seats, seat.number, seat)}

  defp fetch_seat(state, number) do
    case Map.fetch(state.seats, number) do
      {:ok, seat} -> {:ok, seat}
      :error -> {:error, :invalid_seat}
    end
  end

  defp fetch_player(state, user_id) do
    case find_seat(state, user_id) do
      nil -> {:error, :not_seated}
      seat -> {:ok, seat}
    end
  end

  defp ensure_open(%__MODULE__{draining?: true}), do: {:error, :room_closing}
  defp ensure_open(_state), do: :ok

  defp ensure_free(%Seat{status: :empty}), do: :ok
  defp ensure_free(_seat), do: {:error, :seat_taken}

  defp ensure_not_seated(state, user_id) do
    # Мультитейблинг разрешён; ограничение ровно одно — одно место в комнате.
    if find_seat(state, user_id), do: {:error, :already_seated}, else: :ok
  end

  defp ensure_between_hands(%__MODULE__{phase: :hand}), do: {:error, :hand_in_progress}
  defp ensure_between_hands(_state), do: :ok
end
