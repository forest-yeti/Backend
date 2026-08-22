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

  alias BlockPoker.Engine.{
    BombPot,
    ButtonDraw,
    Hand,
    HandSetup,
    HandStats,
    Preselect,
    PrizePool,
    Rabbit,
    Rng,
    Stats
  }

  alias BlockPoker.Engine.Straddle
  alias BlockPoker.Engine.Variant.Registry, as: VariantRegistry
  alias BlockPoker.Tables.{RoomState, Seat, TableRegistry}
  alias Phoenix.PubSub

  @pubsub BlockPoker.PubSub
  @rooms_topic "tables:rooms"

  # Пауза между улицами при доводке борта. Игроку нечего решать — он смотрит,
  # как решается его стек, и должен успеть прочитать каждую улицу отдельно.
  @runout_step_ms 2_500
  # Сколько даётся на ответ про два прогона. Молчание — отказ, поэтому окно
  # короткое: стол не может ждать думающего дольше, чем длится его ход.
  @rit_offer_ms 8_000
  # Сколько стол стоит после вскрытия. Отсюда игрок узнаёт, кто выиграл и
  # сколько, поэтому пауза заметно длиннее любой другой: её укорачивание
  # первым делом ломает читаемость раздачи.
  @next_hand_ms 5_000

  # Сколько доигранный турнир стоит с итоговой таблицей, прежде чем
  # свернуться. Не настройка шаблона: это длительность экрана, а не
  # правило игры.
  @tournament_close_ms 15_000
  # Сколько объявивший страддл думает над суммой. Окно короткое намеренно:
  # оно стоит перед каждой раздачей и платят за него ожиданием все за столом.
  @straddle_offer_ms 3_000
  # Насколько показ rabbit-карт отодвигает следующую раздачу: ровно столько,
  # чтобы их успели рассмотреть, и не настолько, чтобы стол простаивал.
  @rabbit_extra_ms 1_000

  defmodule State do
    @moduledoc false
    @enforce_keys [:room, :timer_mode, :rng, :clock, :evict, :payout]
    defstruct [:room, :timer_mode, :rng, :clock, :evict, :payout, timers: %{}]
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

  @doc """
  Первый шаг докупки: условия проверены, ключ идемпотентности закреплён
  за местом. Повтор той же суммы до зачисления получает **тот же** ключ —
  на нём и держится защита от двойного списания.
  """
  @spec begin_add_chips(GenServer.server(), Ecto.UUID.t(), pos_integer()) ::
          {:ok, String.t(), %{ref: String.t(), amount: pos_integer()} | nil} | {:error, atom()}
  def begin_add_chips(room, user_id, amount) do
    GenServer.call(room, {:begin_add_chips, user_id, amount})
  end

  @spec commit_add_chips(GenServer.server(), Ecto.UUID.t(), String.t()) ::
          {:ok, Seat.t()}
          | {:queued, Seat.t(), pos_integer()}
          | {:already_credited, Seat.t()}
          | {:error, atom()}
  def commit_add_chips(room, user_id, ref) do
    GenServer.call(room, {:commit_add_chips, user_id, ref})
  end

  @doc """
  Отменить отложенную докупку. Возвращает ключ и сумму, которую вызывающий
  обязан вернуть в кошелёк: со стола она снята здесь.
  """
  @spec cancel_add_chips(GenServer.server(), Ecto.UUID.t()) ::
          {:ok, String.t(), pos_integer()} | {:error, atom()}
  def cancel_add_chips(room, user_id) do
    GenServer.call(room, {:cancel_add_chips, user_id})
  end

  @doc "Докупка сорвалась и деньги возвращены: снять ключ с места."
  @spec abort_add_chips(GenServer.server(), Ecto.UUID.t(), String.t()) :: :ok
  def abort_add_chips(room, user_id, ref) do
    GenServer.call(room, {:abort_add_chips, user_id, ref})
  end

  @doc """
  Уйти в паузу. `%{pending: true}` — игрок в раздаче и обязан её доиграть:
  пауза начнётся по её завершении.
  """
  @spec sit_out(GenServer.server(), Ecto.UUID.t()) :: {:ok, map()} | {:error, atom()}
  def sit_out(room, user_id), do: GenServer.call(room, {:sit_out, user_id})

  @doc "Игровое действие. `seq` — счётчик стола, который клиент видел."
  @spec act(GenServer.server(), Ecto.UUID.t(), Hand.action(), non_neg_integer() | nil) ::
          :ok | {:error, atom()}
  def act(room, user_id, action, seq), do: GenServer.call(room, {:act, user_id, action, seq})

  @doc "Длина окна, в котором объявившие страддл называют сумму."
  @spec straddle_offer_ms() :: pos_integer()
  def straddle_offer_ms, do: @straddle_offer_ms

  @doc "Объявить страддл (сумма) или снять объявление (`nil`)."
  @spec straddle(GenServer.server(), Ecto.UUID.t(), pos_integer() | nil) ::
          {:ok, map()} | {:error, atom()}
  def straddle(room, user_id, amount), do: GenServer.call(room, {:straddle, user_id, amount})

  @doc "Выбрать действие заранее (`nil` — снять выбор)."
  @spec preselect(GenServer.server(), Ecto.UUID.t(), Preselect.t() | nil) ::
          :ok | {:error, atom()}
  def preselect(room, user_id, choice), do: GenServer.call(room, {:preselect, user_id, choice})

  @doc "«Не ждать большого блайнда»: намерение войти за взнос."
  @spec request_post(GenServer.server(), Ecto.UUID.t(), boolean()) :: :ok | {:error, atom()}
  def request_post(room, user_id, wanted?) do
    GenServer.call(room, {:request_post, user_id, wanted?})
  end

  @doc "Сообщение в чат стола."
  @spec chat(GenServer.server(), Ecto.UUID.t(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def chat(room, user_id, text), do: GenServer.call(room, {:chat, user_id, text})

  @doc "Реакция за столом: короткий жест, который видят все в топике."
  @spec react(GenServer.server(), Ecto.UUID.t(), term()) ::
          :ok | {:error, atom() | {atom(), pos_integer()}}
  def react(room, user_id, id), do: GenServer.call(room, {:react, user_id, id})

  @doc "Открыть свои карты по желанию."
  @spec show_cards(GenServer.server(), Ecto.UUID.t(), [non_neg_integer()] | :all) ::
          :ok | {:error, atom()}
  def show_cards(room, user_id, cards \\ :all),
    do: GenServer.call(room, {:show_cards, user_id, cards})

  @doc "Ответ игрока на предложение сыграть дважды."
  @spec answer_run_it_twice(GenServer.server(), Ecto.UUID.t(), boolean()) ::
          :ok | {:error, atom()}
  def answer_run_it_twice(room, user_id, accept?),
    do: GenServer.call(room, {:run_it_twice, user_id, accept?})

  @doc "Показать карты, которые пришли бы дальше, если бы раздача доигралась."
  @spec rabbit_hunt(GenServer.server(), Ecto.UUID.t()) :: :ok | {:error, atom()}
  def rabbit_hunt(room, user_id), do: GenServer.call(room, {:rabbit_hunt, user_id})

  @doc "Ручной запуск стола в комнате без автостарта."
  @spec start_game(GenServer.server(), Ecto.UUID.t()) :: :ok | {:error, atom()}
  def start_game(room, user_id), do: GenServer.call(room, {:start_game, user_id})

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
  Запереть комнату под закрытие, если ей нечего терять.

  Решает **сама комната**, а не лобби по своему кэшу занятости: кэш приходит
  асинхронным `{:room_changed, ...}` и отстаёт от резерва места, поэтому
  «пусто» в лобби и «пусто» на самом деле — разные вещи, и между ними
  помещается посадка с уже списанным бай-ином.

  Успех переводит комнату в `:draining` тем же вызовом: после него `reserve`
  отвечает `:room_closing`, и посадка не проскочит в зазор между ответом
  и `terminate_child`.
  """
  @spec close_if_idle(GenServer.server()) :: :ok | {:error, :busy}
  def close_if_idle(room), do: GenServer.call(room, :close_if_idle)

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
      room:
        RoomState.new(room_id, setting, Keyword.get(opts, :game_mode, BlockPoker.GameMode.Cash)),
      timer_mode: Keyword.get(opts, :timers, :real),
      rng: Keyword.get_lazy(opts, :rng, &Rng.default/0),
      # Часы инжектируются: тайм-банк считает прошедшее время, и тесты
      # прогоняют его вручную, а не ожиданием (§11 CLAUDE.md).
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      # Выселение просидевшего паузу — это cash-out, то есть поход в кошелёк,
      # а комната в кошелёк не ходит (см. moduledoc). Поэтому наружу уходит
      # функция, и выполняется она в отдельном процессе: стол не вправе
      # стоять, пока идёт транзакция.
      evict: Keyword.get(opts, :evict, &default_evict/2),
      # Выплата призов — поход в кошелёк, и стол не вправе стоять, пока
      # идёт транзакция. Функция инжектируется по той же причине, что и
      # выселение: комната в кошелёк не ходит.
      payout: Keyword.get(opts, :payout, &default_payout/2)
    }

    # Режим заводит своё состояние сам: стол не спрашивает, турнир это или
    # кэш, — он зовёт колбэк всегда.
    room = state.room.mode.init_room(state.room)
    state = put_room(state, %{room | straddle_allowed?: room.mode.straddle?(room)})

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
          avatar: seat.avatar,
          flair: seat.flair
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

  def handle_call({:straddle, user_id, amount}, _from, state) do
    case RoomState.set_straddle(state.room, user_id, amount) do
      {:ok, room, seat} ->
        state = put_room(state, room)

        # Режим публичен: стол обязан знать, что кто-то ставит вслепую, —
        # это меняет цену раздачи для всех, а не только для объявившего.
        broadcast(state, "straddle_mode", %{seat: seat.number, straddle: seat.straddle})

        {:reply, {:ok, %{straddle: seat.straddle}}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:request_post, user_id, wanted?}, _from, state) do
    case RoomState.request_post(state.room, user_id, wanted?) do
      {:ok, room, seat} ->
        state = put_room(state, room)
        broadcast(state, "seat_posting", %{seat: seat.number, wants_post: seat.wants_post})

        # Стол может стоять в ожидании второго игрока: вошедший за взнос
        # даёт нужного, и раздача начинается сразу, а не через круг.
        {:reply, :ok, maybe_start_game(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Реакция никуда не сохраняется: она уходит в топик и на этом кончается.
  def handle_call({:react, user_id, id}, _from, state) do
    case RoomState.push_reaction(state.room, user_id, id, now_ms(state), DateTime.utc_now()) do
      {:ok, room, event} ->
        state = put_room(state, room)
        broadcast(state, "reaction", event)
        {:reply, :ok, state}

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

  # Показ карт живёт в окне после раздачи, а не в самой раздаче: во время
  # торговли открытая карта — подсказка тем, кто ещё принимает решения.
  # Кому и когда можно, решает `RoomState`, комната лишь рассылает событие.
  def handle_call({:show_cards, user_id, cards}, _from, state) do
    case RoomState.show_cards(state.room, user_id, cards, now_ms(state)) do
      {:ok, room, payload} ->
        state = put_room(state, room)
        broadcast(state, "cards_shown", payload)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Кто вправе отвечать — правило игры, и проверяет его раздача. Сервер лишь
  # переводит `user_id` в место и отдаёт ответ движку.
  def handle_call({:run_it_twice, user_id, accept?}, _from, state) do
    with {:ok, hand} <- fetch_hand(state),
         {:ok, seat} <- seat_of(state, user_id),
         {:ok, hand, events} <- Hand.answer_run_it_twice(hand, seat, accept?) do
      {:reply, :ok, apply_hand(state, hand, events)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Карты уходят **адресно каждому сидящему**, а не в общий топик: за столом
  # их видят все игроки, наблюдатель — никто. Broadcast сделал бы обратное.
  def handle_call({:rabbit_hunt, user_id}, _from, state) do
    case RoomState.reveal_rabbit(state.room, user_id, now_ms(state), @rabbit_extra_ms) do
      {:ok, room, runout} ->
        state = put_room(state, room)

        state =
          Enum.reduce(
            seated_users(room),
            state,
            &private(&2, &1, "rabbit_cards", %{streets: runout})
          )

        {:reply, :ok, extend_pause(state)}

      # Карты уже открыты: повтор доигрывает только запросившему и паузу
      # не двигает — иначе кнопка стала бы способом тормозить стол.
      {:revealed, runout} ->
        {:reply, :ok, private(state, user_id, "rabbit_cards", %{streets: runout})}

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
    room = RoomState.cancel_leave(state.room, ref, stack, sit_out_deadline(state))
    state = put_room(state, room)

    # Уход не состоялся, игрок остался сидеть в паузе — и держится она тем же
    # сроком, что любая другая: место не может быть занято вечно из-за
    # неудавшейся транзакции.
    case Enum.find(
           RoomState.seats(state.room),
           &(&1.status == :sitting_out and &1.stack == stack)
         ) do
      nil -> {:reply, :ok, state}
      seat -> {:reply, :ok, arm_sit_out(state, seat.number)}
    end
  end

  def handle_call({:begin_add_chips, user_id, amount}, _from, state) do
    case RoomState.begin_add_chips(state.room, user_id, amount, new_ref()) do
      {:ok, room, ref, replaced} ->
        state = put_room(state, room)
        if replaced, do: announce(state)
        {:reply, {:ok, ref, replaced}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:commit_add_chips, user_id, ref}, _from, state) do
    case RoomState.commit_add_chips(state.room, user_id, ref) do
      {:ok, room, seat} ->
        state =
          state
          |> put_room(room)
          |> cancel_timer({:rebuy, seat.number})
          # Докупка вернула игрока в игру — держать над ним таймер паузы
          # больше не за что.
          |> cancel_timer({:sit_out, seat.number})
          |> maybe_start_game()

        announce(state)
        broadcast(state, "chips_added", %{seat: seat.number, stack: seat.stack})
        {:reply, {:ok, seat}, state}

      # Идёт раздача: деньги списаны, но фишки лягут на стол только в начале
      # следующей. Стол объявляет заявку сразу — эффективный стек этого места
      # через раздачу вырастет, и знать об этом должны все, а не только
      # заказавший.
      {:queued, room, seat, amount} ->
        state = state |> put_room(room) |> cancel_timer({:rebuy, seat.number})

        announce(state)
        broadcast(state, "add_chips_queued", %{seat: seat.number, amount: amount})
        {:reply, {:queued, seat, amount}, state}

      # Ключ уже отработал: фишки на столе, второй раз их зачислять нечего
      # и возвращать нечего. Повтор отличается от первого вызова только тем,
      # что стол уже ничего не меняет.
      {:already_credited, seat} ->
        {:reply, {:already_credited, seat}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cancel_add_chips, user_id}, _from, state) do
    case RoomState.cancel_add_chips(state.room, user_id) do
      {:ok, room, ref, amount} ->
        state = put_room(state, room)
        seat = RoomState.find_seat(state.room, user_id)

        announce(state)
        broadcast(state, "add_chips_cancelled", %{seat: seat.number})
        {:reply, {:ok, ref, amount}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:abort_add_chips, user_id, ref}, _from, state) do
    {:reply, :ok, put_room(state, RoomState.abort_add_chips(state.room, user_id, ref))}
  end

  def handle_call({:sit_out, user_id}, _from, state) do
    case RoomState.request_sit_out(state.room, user_id, sit_out_deadline(state)) do
      {:ok, room, applied} ->
        state = put_room(state, room)
        seat = RoomState.find_seat(state.room, user_id)

        state =
          case applied do
            :applied ->
              start_sit_out(state, seat.number, "sit_out")

            # Решение объявляется сразу: стол видит, что игрок доигрывает
            # последнюю раздачу, а не гадает, почему он вдруг пропал.
            :pending ->
              broadcast(state, "sit_out_pending", %{seat: seat.number})
              state
          end

        announce(state)
        {:reply, {:ok, %{pending: applied == :pending}}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Стол без автостарта ждёт этой команды ровно один раз — на розыгрыш
  # кнопки. Дальше раздачи идут сами, как за любым другим столом.
  def handle_call({:start_game, user_id}, _from, state) do
    case RoomState.validate_manual_start(state.room, user_id) do
      :ok ->
        state = start_button_draw(state, playable_seats(state.room))
        announce(state)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:sit_in, user_id}, _from, state) do
    case RoomState.sit_in(state.room, user_id) do
      {:ok, room} ->
        seat = RoomState.find_seat(room, user_id)

        state =
          state
          |> put_room(room)
          |> cancel_timer({:sit_out, seat.number})

        broadcast(state, "seat_sitting_in", %{seat: seat.number})
        announce(state)
        maybe_start_game_after_sit_in(state)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
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

  def handle_call(:close_if_idle, _from, state) do
    if RoomState.closable?(state.room) do
      {:reply, :ok, put_room(state, RoomState.mark_draining(state.room))}
    else
      {:reply, {:error, :busy}, state}
    end
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
        if state.room.mode.can_leave?(state.room, seat),
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

  # Итоговую таблицу показали — турнир сворачивается.
  defp do_timeout(:tournament_close, state), do: close_tournament(state)

  # Grace-период истёк: место освобождается, фишки возвращать некому —
  # это делает `Tables`, поэтому наружу уходит событие.
  defp do_timeout({:grace, seat_number}, state) do
    room = RoomState.expire_grace(state.room, seat_number, sit_out_deadline(state))
    state = state |> put_room(room) |> start_sit_out(seat_number, "disconnected")
    announce(state)
    state
  end

  # Пауза кончилась: место возвращается столу, фишки — в кошелёк игрока.
  # Кэш-стол на шесть мест не может держать кресло за отошедшим бесконечно,
  # а решать за игрока «доиграет — не доиграет» некому.
  defp do_timeout({:sit_out, seat_number}, state) do
    case Map.fetch(state.room.seats, seat_number) do
      {:ok, %Seat{user_id: user_id} = seat} when user_id != nil ->
        broadcast(state, "sit_out_expired", %{seat: seat.number, user_id: user_id})
        state.evict.(state.room.room_id, user_id)
        state

      _other ->
        state
    end
  end

  # Окно на докупку истекло: место возвращается столу. Игрок с нулевым стеком
  # не играет, а кресло за кэш-столом — дефицит; уход при этом всё равно идёт
  # обычным путём, а не «освобождением места» здесь: стек нулевой не всегда —
  # между истечением и этой строкой могла пройти докупка, чей ключ уже
  # отработал, и терять её фишки нельзя.
  defp do_timeout({:rebuy, seat_number}, state) do
    case Map.fetch(state.room.seats, seat_number) do
      {:ok, %Seat{user_id: user_id} = seat} when user_id != nil ->
        broadcast(state, "rebuy_expired", %{seat: seat.number, user_id: user_id})
        state.evict.(state.room.room_id, user_id)
        state

      _other ->
        state
    end
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

  # Окно объявления суммы закрылось: молчание — согласие на объявленную
  # ранее сумму, а не отказ. Дальше раздача идёт обычным путём.
  defp do_timeout(:straddle, state) do
    state = put_room(state, RoomState.close_straddle_window(state.room))
    start_hand(state)
  end

  # Время на ответ вышло: неотвеченное — отказ, и доводка идёт одним бордом.
  defp do_timeout(:rit, state) do
    with {:ok, hand} <- fetch_hand(state),
         {:ok, hand, events} <- Hand.close_run_it_twice(hand) do
      apply_hand(state, hand, events)
    else
      {:error, _reason} -> state
    end
  end

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

  # Окно страддла уже открыто: раздача ждёт его, а севший в этот момент
  # игрок не должен открывать второе.
  defp start_hand(%State{room: %RoomState{phase: :straddle}} = state), do: state

  defp start_hand(state), do: start_hand(state, length(in_game_seats(state.room)))

  # `attempts` — по одному обороту блайндов на каждое занятое место: если за
  # столом одни ждущие BB, блайнд обязан до кого-то из них дойти, но круг
  # должен быть конечным.
  defp start_hand(state, attempts) when attempts <= 0, do: state

  defp start_hand(state, attempts) do
    # Кнопка проверяется **здесь**, а не только по концу прошлой раздачи:
    # между раздачами игрок вправе встать, и кнопка остаётся на месте,
    # которое эту раздачу не играет. Позиции тогда считаются от пустого
    # кресла — блайнды платят не те.
    # Отложенные докупки — первым шагом: до отбора играющих мест и до
    # блайндов. Иначе обнулившийся и тут же докупившийся игрок пропустил бы
    # раздачу, за которую уже заплатил.
    state = apply_queued_add_chips(state)
    state = maybe_draw_prize(state)
    state = maybe_advance_level(state)
    state = put_room(state, ensure_button_in_play(state.room))
    state = roll_bomb_pot(state)

    case offer_straddle(state) do
      {:open, state} -> state
      :none -> deal_hand(state, attempts)
    end
  end

  # Объявившим страддл даётся окно назвать сумму — до карт и до блайндов:
  # ставка вслепую тем и является, что делается вслепую. Окно открывается
  # один раз на раздачу (`straddle_done?`) и только если объявившие есть:
  # стол без страддла не должен ждать ни секунды.
  defp offer_straddle(%State{room: %RoomState{straddle_done?: true}}), do: :none

  # В бомб-поте страддла нет: ставка вслепую поднимает цену префлопа, а
  # префлопа в этой раздаче не будет. Объявления при этом не снимаются —
  # они сработают на следующей обычной раздаче.
  defp offer_straddle(%State{room: %RoomState{bomb_pot: bomb_pot}}) when bomb_pot != nil,
    do: :none

  defp offer_straddle(state) do
    seats = in_game_seats(state.room)
    intents = RoomState.straddle_intents(state.room, seats)

    if length(seats) >= 2 and intents != [] do
      state =
        put_room(state, RoomState.open_straddle_window(state.room, straddle_deadline(state)))

      broadcast(state, "straddle_offer", %{
        deadline_ms: @straddle_offer_ms,
        min: Straddle.min_amount(RoomState.bet_unit(state.room)),
        seats: intents
      })

      {:open, schedule(state, :straddle, @straddle_offer_ms)}
    else
      :none
    end
  end

  defp straddle_deadline(state), do: now_ms(state) + @straddle_offer_ms

  # Кубик бросается один раз на раздачу и **до** карт: игрок обязан узнать,
  # что раздача бомбовая, раньше, чем увидит свои карты, — иначе взнос
  # оказывается платой за уже известную руку.
  #
  # RNG возвращается в состояние стола: раздача воспроизводится по seed
  # целиком, включая сам бросок.
  defp roll_bomb_pot(%State{room: %RoomState{bomb_pot_rolled?: true}} = state), do: state

  defp roll_bomb_pot(state) do
    case state.room.mode.bomb_pot(state.room) do
      nil ->
        put_room(state, RoomState.put_bomb_pot(state.room, nil))

      %{chance: chance, ante: ante} ->
        {bomb?, rng} = BombPot.roll(state.rng, chance)
        bomb_pot = if bomb?, do: %{ante: ante}, else: nil
        state = put_room(%{state | rng: rng}, RoomState.put_bomb_pot(state.room, bomb_pot))

        if bomb?, do: broadcast(state, "bomb_pot", %{ante: ante})

        state
    end
  end

  # Приз тянется один раз за турнир и **до** первой карты: игрок обязан
  # знать, за что играет, раньше, чем сядет играть. RNG возвращается в
  # состояние стола — розыгрыш воспроизводится по seed, как и раздача.
  defp maybe_draw_prize(%State{room: %RoomState{tournament: %{prize: %{}}}} = state), do: state

  defp maybe_draw_prize(state) do
    case state.room.mode.prize_table(state.room) do
      nil ->
        state

      tiers ->
        {tier, rng} = PrizePool.draw(state.rng, tiers)
        prize = build_prize(state.room, tier)

        state =
          %{state | rng: rng}
          |> put_room(RoomState.put_prize(state.room, prize))
          |> then(&put_room(&1, RoomState.arm_level(&1.room, now_ms(&1))))

        broadcast(state, "prize_revealed", prize)
        state
    end
  end

  defp build_prize(%RoomState{setting: setting}, tier) do
    %{
      multiplier: tier.multiplier,
      label: PrizePool.multiplier_label(tier.multiplier),
      pool: PrizePool.prize_pool(setting.buy_in, tier.multiplier),
      payouts: tier.payouts
    }
  end

  # Уровень поднимается **между раздачами**, и проверяется это здесь, а не
  # таймером: поднимать номиналы посреди улицы нельзя — это меняет цену уже
  # принятого решения. Таймер при этом не нужен вовсе, а дедлайн, который
  # проспали на длинной раздаче, догоняется циклом: время шло, и уровней
  # могло смениться несколько.
  defp maybe_advance_level(%State{room: %RoomState{tournament: nil}} = state), do: state

  defp maybe_advance_level(
         %State{room: %RoomState{tournament: %{level_deadline_at: nil}}} = state
       ),
       do: state

  defp maybe_advance_level(state) do
    if now_ms(state) >= state.room.tournament.level_deadline_at do
      room = RoomState.advance_level(state.room, now_ms(state))
      state = put_room(state, room)

      broadcast(state, "level_up", level_view(room, now_ms(state)))

      maybe_advance_level(state)
    else
      state
    end
  end

  # Часы приходят аргументом, а не берутся из системы: тайминги стола
  # прогоняются в тестах вручную (§11 CLAUDE.md).
  defp level_view(%RoomState{tournament: tournament} = room, now) do
    level = RoomState.current_level(room)

    %{
      level: tournament.level,
      small_blind: level.small_blind,
      big_blind: level.big_blind,
      ante: level.ante,
      next_level_in_ms: remaining_level_ms(room, now)
    }
  end

  defp remaining_level_ms(%RoomState{tournament: %{level_deadline_at: nil}}, _now), do: nil

  defp remaining_level_ms(%RoomState{tournament: tournament}, now) do
    max(tournament.level_deadline_at - now, 0)
  end

  # Страддл в раздаче один, и выбирает его чистое ядро: заявок могло прийти
  # несколько, а спорят они суммой и позицией — это правило игры (§3).
  defp resolve_straddle(state, setup) do
    order = setup |> HandSetup.order_from_button() |> Enum.map(& &1.seat)
    intents = RoomState.straddle_intents(state.room, order)

    %{setup | straddle: Straddle.choose(intents, order)}
  end

  defp deal_hand(state, attempts) do
    # Намерения превращаются в решения ровно здесь: кнопка на месте, и
    # стоимость входа считается по той обстановке, в которой раздача пойдёт.
    state = put_room(state, RoomState.resolve_post_intents(state.room))
    state = put_room(state, activate_big_blind(state.room))

    case state.room.mode.hand_setup(state.room) do
      {:ok, setup} ->
        setup = resolve_straddle(state, setup)
        {hand, events} = Hand.start(setup, state.rng, rake: rake_fun(state))
        room = RoomState.clear_posts(state.room, Map.keys(hand.players))

        state =
          put_room(state, %{
            RoomState.reset_straddle_window(room)
            | phase: :hand,
              hand: hand,
              hand_stats: HandStats.new(hand),
              showdown: nil,
              rabbit: nil,
              # Новая раздача закрывает окно показа прошлой: карты, которые
              # не открыли за паузу, остаются закрытыми навсегда.
              reveal: nil
          })

        broadcast(state, "hand_started", %{
          button_seat: setup.button_seat,
          straddle: setup.straddle,
          # Взнос бомб-пота либо `nil`: раздача, начинающаяся с флопа,
          # обязана объявить себя тем же событием, что и обычная.
          bomb_pot: setup.bomb_pot,
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

  # Кнопка стоит на месте, которое раздачу не играет (игрок встал, ушёл
  # в сит-аут или проиграл стек) — двигаем её дальше по кругу вместе
  # с блайндами. Стоящую на играющем месте кнопку не трогаем: раз в раздачу
  # она уже сдвинулась в `finish_hand/2`.
  defp ensure_button_in_play(room) do
    seats = playing_seats(room)

    if seats == [] or room.button_seat in seats do
      room
    else
      rotate_blinds(room)
    end
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
    fn pot, players, opts -> state.room.mode.rake(setting, pot, players, opts) end
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
      Hand.offering_run_it_twice?(hand) -> arm_rit_timer(state)
      hand.runout? -> schedule(cancel_timer(state, :action), :runout, @runout_step_ms)
      true -> advance_to_actor(state, hand)
    end
  end

  # Окно ответа взводится один раз: повторный `apply_hand/3` внутри того же
  # окна (ответил первый из двоих) не должен продлевать его второму.
  defp arm_rit_timer(%State{room: %RoomState{rit_deadline_at: nil}} = state) do
    state = put_room(state, %{state.room | rit_deadline_at: now_ms(state) + @rit_offer_ms})
    schedule(cancel_timer(state, :action), :rit, @rit_offer_ms)
  end

  defp arm_rit_timer(state), do: state

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

  defp sit_out_timeout_ms(state), do: state.room.mode.sit_out_timeout_ms(state.room)

  # `nil` — режим, в котором пауза бессрочна: место не освобождается, и
  # возвращать фишки некуда. Турнир именно такой, и это не тайм-аут длиной
  # в бесконечность, а отсутствие механики.
  defp sit_out_deadline(state) do
    case sit_out_timeout_ms(state) do
      nil -> nil
      ms -> now_ms(state) + ms
    end
  end

  # Отложенные паузы становятся настоящими ровно здесь: раздача доиграна,
  # обязательств у игрока больше нет.
  defp apply_pending_sit_outs(state) do
    {room, seats} = RoomState.apply_pending_sit_outs(state.room, sit_out_deadline(state))

    Enum.reduce(seats, put_room(state, room), &start_sit_out(&2, &1, "sit_out"))
  end

  defp start_sit_out(state, seat_number, reason) do
    state = arm_sit_out(state, seat_number)
    broadcast(state, "seat_sitting_out", %{seat: seat_number, reason: reason})
    state
  end

  defp arm_sit_out(state, seat_number) do
    schedule(state, {:sit_out, seat_number}, sit_out_timeout_ms(state))
  end

  # Вернувшийся из паузы игрок мог оказаться вторым за столом — стол,
  # остановленный «некому играть», обязан от этого поехать снова.
  defp maybe_start_game_after_sit_in(state) do
    {:reply, :ok, maybe_start_game(state)}
  end

  # Турнир, доигранный до одного живого, рассчитывается ровно один раз:
  # режим сам следит за этим флагом, стол только спрашивает.
  defp maybe_settle(state) do
    if state.room.mode.finished?(state.room) do
      results = state.room.mode.results(state.room)
      room = RoomState.settle_tournament(state.room)
      state = put_room(state, room)

      broadcast(state, "tournament_finished", %{
        prize: room.tournament && room.tournament.prize,
        results: results
      })

      state.payout.(room, results)

      # Стол не исчезает в ту же секунду: игроки должны увидеть итоговую
      # таблицу. По истечении паузы места освобождаются и комната уходит
      # в drain — без этого доигранный турнир не опустеет никогда,
      # потому что вылетевшие остаются за столом зрителями.
      schedule(state, :tournament_close, @tournament_close_ms)
    else
      state
    end
  end

  defp close_tournament(state) do
    room = state.room |> RoomState.clear_seats() |> RoomState.mark_draining()
    state = put_room(state, room)

    announce(state)
    state
  end

  defp apply_queued_add_chips(state) do
    {room, applied} = RoomState.apply_queued_add_chips(state.room)
    state = put_room(state, room)

    Enum.each(applied, fn entry ->
      broadcast(state, "chips_added", %{
        seat: entry.seat,
        stack: RoomState.find_seat(state.room, entry.user_id).stack
      })

      # Урезанный остаток возвращается в кошелёк вне процесса: стол не имеет
      # права ждать базу, держа в руках начало раздачи.
      if entry.refund > 0 do
        return_chips_async(state.room, entry.user_id, entry.refund, entry.ref)
      end
    end)

    if applied != [], do: announce(state)

    state
  end

  defp return_chips_async(%RoomState{} = room, user_id, amount, ref) do
    Task.start(fn -> BlockPoker.Tables.return_chips(room, user_id, amount, "trim:#{ref}") end)
  end

  defp default_payout(%RoomState{} = room, results) do
    Task.start(fn -> BlockPoker.Tables.pay_out(room, results) end)
    :ok
  end

  defp default_evict(room_id, user_id) do
    Task.start(fn -> BlockPoker.Tables.leave_seat(room_id, user_id) end)
    :ok
  end

  defp finish_hand(state, hand) do
    state = state |> cancel_timer(:action) |> cancel_timer(:runout) |> cancel_timer(:rit)

    state = record_stats(state, hand)

    room =
      %{
        state.room
        | hand: nil,
          hand_stats: nil,
          deadline_at: nil,
          time_bank_at: nil,
          rit_deadline_at: nil,
          showdown: nil
      }
      |> RoomState.clear_preselects()
      |> RoomState.reset_straddle_window()
      |> RoomState.reset_bomb_pot()
      |> RoomState.refill_time_banks(owners_of(hand))

    room = state.room.mode.on_hand_finished(room, hand.results)
    room = %{room | button_seat: next_button(room)}
    room = %{room | big_blind_seat: big_blind_seat_for(room)}
    room = put_rabbit(room, hand, now_ms(state))

    # Окно показа живёт ту же паузу, что и стол стоит после раздачи.
    room = RoomState.put_reveal(room, hand, now_ms(state) + @next_hand_ms)

    state =
      state
      |> put_room(room)
      |> handle_broke_players(hand)
      |> apply_pending_sit_outs()
      |> maybe_stop_game()
      |> maybe_settle()

    announce(state)

    if length(RoomState.players(state.room)) >= 2 and state.room.game_started? do
      schedule(state, :next_hand, @next_hand_ms)
    else
      state
    end
  end

  # Снимок заводится только там, где раздача кончилась фолдом на неполном
  # борде: решает это чистый `Engine.Rabbit`, а не условие в оболочке.
  defp put_rabbit(room, hand, now) do
    case Rabbit.runout(hand) do
      {:ok, runout} -> RoomState.put_rabbit(room, runout, now + @next_hand_ms)
      {:error, _reason} -> RoomState.clear_rabbit(room)
    end
  end

  # Пауза догоняет продлённое окно. Если следующая раздача не запланирована
  # (игроков меньше двух, игра остановлена), двигать нечего.
  defp extend_pause(%State{room: %RoomState{rabbit: rabbit}} = state) do
    if Map.has_key?(state.timers, :next_hand) do
      schedule(state, :next_hand, max(rabbit.expires_at - now_ms(state), 0))
    else
      state
    end
  end

  defp seated_users(room), do: room |> RoomState.players() |> Enum.map(& &1.user_id)

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
  # Вылетевшие обрабатываются в порядке стартового стека — от меньшего
  # к большему. Порядок важен там, где в одной раздаче вылетают двое:
  # места между ними делятся по стеку на её начало, а не по тому, в каком
  # порядке карта мест отдала свои ключи.
  defp handle_broke_players(state, hand) do
    hand.players
    |> Enum.sort_by(fn {_number, player} -> player.stack + player.total end)
    |> Enum.reduce(state, fn {number, _player}, acc ->
      seat = Map.get(acc.room.seats, number)

      if seat != nil and seat.stack == 0 and Seat.occupied?(seat) do
        acc
        |> put_room(acc.room.mode.on_zero_stack(acc.room, seat))
        |> schedule({:rebuy, number}, acc.room.mode.rebuy_prompt_ms(acc.room))
      else
        acc
      end
    end)
  end

  # Кнопка двигается по местам, которые **играют раздачу**, а не просто
  # сидят за столом: ждущий большого блайнда в раздаче не участвует, и
  # кнопка на его месте оставляла раздачу без малого блайнда.
  defp next_button(room) do
    case playing_seats(room) do
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

  # Большой блайнд, наоборот, считается по всем сидящим: именно так он
  # доходит до ждущего игрока и вводит его в игру (`activate_big_blind/1`).
  # Большой блайнд, наоборот, считается по всем сидящим: именно так он
  # доходит до ждущего игрока и вводит его в игру (`activate_big_blind/1`).
  defp big_blind_seat_for(room) do
    case in_game_seats(room) do
      [] -> nil
      seats -> big_blind_seat(room.button_seat, seats)
    end
  end

  defp in_game_seats(room) do
    room |> RoomState.players() |> Enum.map(& &1.number) |> Enum.sort()
  end

  defp playing_seats(room) do
    room |> RoomState.seats() |> Enum.filter(&Seat.in_game?/1) |> Enum.map(& &1.number)
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

  # Вопрос закрыт: гасим окно вместе с его таймером — иначе просроченный тик
  # попытался бы закрыть его второй раз.
  defp emit({:run_it_twice_decided, payload}, state) do
    state = put_room(cancel_timer(state, :rit), %{state.room | rit_deadline_at: nil})
    broadcast(state, "run_it_twice_decided", payload)
    state
  end

  defp emit({:equity_update, runs}, state) do
    showdown = Map.put(state.room.showdown || %{}, :equity, runs)
    state = put_room(state, %{state.room | showdown: showdown})
    broadcast(state, "equity_update", %{runs: runs})
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

  # Таймер, которого у режима нет, не заводится вовсе: снимаем возможный
  # прежний и уходим. Иначе `nil` доехал бы до `Process.send_after/3`.
  defp schedule(state, key, nil), do: cancel_timer(state, key)

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
      {kind, seat} when kind in [:grace, :rebuy, :sit_out] -> not MapSet.member?(occupied, seat)
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
  # Кнопка ещё разыгрывается: севший в этот момент игрок раздачу не начинает.
  # Иначе она стартовала бы посреди анимации, а доигравший её таймер розыгрыша
  # начинал бы поверх неё вторую.
  defp maybe_start_game(%State{room: %RoomState{phase: :button_draw}} = state), do: state

  defp maybe_start_game(%State{room: %RoomState{game_started?: true, hand: nil}} = state) do
    start_hand(state)
  end

  defp maybe_start_game(%State{room: %RoomState{game_started?: true}} = state), do: state

  # Комната с `auto_start: false` сама не стартует, сколько бы игроков за ней
  # ни собралось: первую кнопку разыгрывает администратор командой `start_game`.
  defp maybe_start_game(%State{room: room} = state) do
    seats = playable_seats(room)

    if RoomState.auto_start?(room) and length(seats) >= room.mode.start_threshold(room) do
      start_button_draw(state, seats)
    else
      state
    end
  end

  defp playable_seats(room),
    do: room |> RoomState.players() |> Enum.map(& &1.number) |> Enum.sort()

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
    # Кнопки может не оказаться среди этих мест (игрок встал, сел в сит-аут).
    # Без этой проверки `drop_while` крутится по бесконечному циклу вечно,
    # и процесс стола встаёт колом — это хуже падения: его никто не заметит.
    if button_seat in seats do
      seats
      |> Stream.cycle()
      |> Stream.drop_while(&(&1 != button_seat))
      |> Enum.take(3)
      |> List.last()
    else
      Enum.at(seats, 1, hd(seats))
    end
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
