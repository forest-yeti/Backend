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

  alias BlockPoker.Engine.{
    BlindSchedule,
    BombPot,
    Card,
    Discipline,
    EntryRules,
    Hand,
    HandInsight,
    Preselect,
    Straddle,
    Stats,
    TimeBank
  }

  alias BlockPoker.Engine.Variant.Registry, as: VariantRegistry
  alias BlockPoker.Reactions
  alias BlockPoker.SitAndGo.SitAndGoSetting
  alias BlockPoker.Tables.Seat

  @type phase :: :idle | :button_draw | :straddle | :hand
  @type entry :: :wait_bb | :post

  @typedoc "Снимок профиля игрока: то, чем стол его показывает."
  @type profile :: %{
          optional(:name) => String.t(),
          optional(:avatar) => String.t(),
          optional(:flair) => String.t(),
          optional(:role) => Seat.role()
        }

  @typedoc """
  Шаблон, из которого развёрнута комната. Тип зависит от режима: кэш живёт
  из `CashGameSetting`, Sit & Go — из `SitAndGoSetting`.

  Комната читает из шаблона только то, что есть у обоих: вместимость, вид
  игры, тайминги, косметику. Всё, что различается, спрашивается у режима
  (`GameMode`), а не выбирается ветвлением по типу структуры.
  """
  @type setting :: CashGameSetting.t() | SitAndGoSetting.t()

  @type t :: %__MODULE__{
          room_id: Ecto.UUID.t(),
          setting: setting(),
          mode: module(),
          discipline: module(),
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
          showdown: map() | nil,
          rit_deadline_at: integer() | nil,
          straddle_allowed?: boolean(),
          straddle_deadline_at: integer() | nil,
          straddle_done?: boolean(),
          bomb_pot: BombPot.t() | nil,
          bomb_pot_rolled?: boolean(),
          rabbit: rabbit() | nil,
          reveal: reveal() | nil,
          tournament: tournament() | nil
        }

  @typedoc """
  Окно добровольного показа карт после раздачи.

  Правила покера не обязывают показывать руку, которую никто не купил:
  забравший банк по фолдам и ушедший в мук на вскрытии вправе оставить
  карты закрытыми. Но и запрета нет — открыться можно, и это часть игры.

  Окно живёт ровно паузу между раздачами и хранит **только карманные карты
  прошедшей раздачи**: показывать по нему больше нечего, а утечь оттуда
  нечему. `shown` — индексы уже открытых карт по местам: показать можно и
  одну карту, и обе, и повтор ничего не меняет.
  """
  @type reveal :: %{
          cards: %{pos_integer() => [map()]},
          users: %{pos_integer() => Ecto.UUID.t()},
          shown: %{pos_integer() => [non_neg_integer()]},
          expires_at: integer()
        }

  @typedoc """
  Снимок для rabbit hunting: карты недостающих улиц прошедшей раздачи.

  Хранится **только результат** — сами карты, а не хвост колоды: остаток
  колоды рядом с живой комнатой не нужен никому, а утечь может. Снимок
  заводится по концу раздачи, живёт до старта следующей и обнуляется ею.
  """
  @type rabbit :: %{
          runout: [map()],
          expires_at: integer(),
          revealed?: boolean()
        }

  @typedoc """
  Турнирное состояние комнаты: уровень, приз и порядок вылета.

  Лежит в комнате, а не в процессе стола, по той же причине, что и окно
  страддла: игрок, подключившийся посреди турнира, обязан увидеть то же,
  что видят остальные, — какой сейчас уровень, когда он сменится и за
  какой приз идёт игра.

  `nil` означает «это не турнир». Ветвления по этому полю в комнате нет:
  читает его только режим (`GameMode.Tournament`), которому оно и
  принадлежит.

  `standings` — порядок вылета в обратном порядке, первым последний
  выбывший. Он и есть распределение мест: в Sit & Go место определяется
  тем, кто вылетел раньше, а победитель дописывается последним.
  """
  @type tournament :: %{
          level: pos_integer(),
          levels: [BlindSchedule.level()],
          level_deadline_at: integer() | nil,
          prize: prize() | nil,
          settled?: boolean(),
          standings: [%{seat: pos_integer(), user_id: Ecto.UUID.t(), place: pos_integer()}]
        }

  @typedoc """
  Выпавший призовой тир: множитель, фонд в минимальных единицах и доли
  мест. Тянется один раз до первой раздачи и больше не меняется.
  """
  @type prize :: %{
          multiplier: pos_integer(),
          label: String.t(),
          pool: non_neg_integer(),
          payouts: [pos_integer()]
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
    # Режим игры: политика между раздачами (`GameMode`). Модуль, а не флаг,
    # — ветвление по режиму существует ровно в одном месте, при выборе
    # реализации, и `case` по :cash / :tournament в комнате не появляется.
    mode: BlockPoker.GameMode.Cash,
    # Дисциплина: что вообще происходит внутри раздачи (`Engine.Discipline`).
    # Модуль, а не флаг, — по той же причине, что и режим: ветвление по
    # дисциплине существует ровно в одном месте, при выборе реализации.
    discipline: BlockPoker.Engine.Hand,
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
    showdown: nil,
    # Дедлайн ответа на предложение сыграть дважды (монотонные мс). Хранится
    # рядом с `deadline_at` и по той же причине: вернувшийся внутри окна
    # игрок должен увидеть остаток времени, а не начать отсчёт заново.
    rit_deadline_at: nil,
    # Снимок rabbit hunting прошедшей раздачи; живёт паузу между раздачами.
    rabbit: nil,
    # Окно добровольного показа карт; живёт ту же паузу и той же длины.
    reveal: nil,
    # Разрешён ли за этим столом страддл. Решает режим игры (`GameMode`),
    # а не шаблон: в кэше он есть всегда, в любом другом формате его нет.
    straddle_allowed?: false,
    # Дедлайн окна, в котором объявившие страддл называют сумму (монотонные
    # мс). Хранится рядом с `deadline_at` и по той же причине: подключившийся
    # внутри окна обязан увидеть остаток, а не начать отсчёт заново.
    straddle_deadline_at: nil,
    # Окно этой раздачи уже прошло. Без флага раздача, которую окно
    # откладывает, откладывалась бы им бесконечно.
    straddle_done?: false,
    # Решение по ближайшей раздаче: взнос бомб-пота либо `nil` — обычная
    # раздача. Хранится рядом с окном страддла и по той же причине: оно
    # принято **до** карт, и подключившийся между раздачами должен увидеть
    # то же, что и остальные.
    bomb_pot: nil,
    # Кубик на эту раздачу уже брошен. Флаг обязателен: `start_hand`
    # переигрывается (кнопка, ожидающие блайнда, окно страддла), а бросков
    # на раздачу должно быть ровно ноль или один.
    bomb_pot_rolled?: false,
    # Турнирное состояние либо `nil` — см. `t:tournament/0`.
    tournament: nil
  ]

  @doc """
  Новая комната из шаблона.

  Режим и дисциплина передаются модулями и хранятся **в комнате**, а не в
  процессе стола: так у вопросов «кэш это или турнир» и «холдем это или
  раскладка» остаётся один источник истины, и чистые функции комнаты
  отвечают на них без обращения к `TableServer`.
  """
  @spec new(Ecto.UUID.t(), setting(), module(), module()) :: t()
  def new(room_id, setting, mode \\ BlockPoker.GameMode.Cash, discipline \\ Hand) do
    seats = Map.new(1..setting.max_players, fn number -> {number, Seat.new(number)} end)

    %__MODULE__{
      room_id: room_id,
      setting: setting,
      mode: mode,
      discipline: discipline,
      seats: seats
    }
  end

  @doc """
  Заводит турнирное состояние: расписание уровней, первый уровень, пустой
  список мест.

  Приз здесь не тянется: розыгрыш требует случайности, а комната ею не
  владеет — её источник принадлежит столу, как и бросок бомб-пота.
  """
  @spec start_tournament(t(), [BlindSchedule.level()]) :: t()
  def start_tournament(%__MODULE__{} = state, levels) do
    %{
      state
      | tournament: %{
          level: 1,
          levels: levels,
          level_deadline_at: nil,
          prize: nil,
          settled?: false,
          standings: []
        }
    }
  end

  @doc """
  Отмечает турнир рассчитанным.

  Флаг существует ради денег: «живой остался один» — состояние, а не
  событие, и без отметки оно выполнялось бы на каждой следующей проверке,
  выплачивая приз повторно.
  """
  @spec settle_tournament(t()) :: t()
  def settle_tournament(%__MODULE__{tournament: nil} = state), do: state

  def settle_tournament(%__MODULE__{tournament: tournament} = state),
    do: %{state | tournament: %{tournament | settled?: true}}

  @doc "Номиналы текущего уровня. У не-турнира их нет."
  @spec current_level(t()) :: BlindSchedule.level() | nil
  def current_level(%__MODULE__{tournament: nil}), do: nil

  def current_level(%__MODULE__{tournament: tournament}),
    do: BlindSchedule.at(tournament.levels, tournament.level)

  @doc """
  Поднимает уровень на следующий и назначает дедлайн следующего повышения.

  Повышение применяется **между раздачами**: поднимать номиналы посреди
  улицы нельзя — это меняет цену уже принятого решения. Следит за этим
  вызывающий, а не эта функция: она только считает.

  `nil` в дедлайне означает, что расти больше некуда — последний уровень
  действует до конца турнира, и таймер под него не заводится.
  """
  @spec advance_level(t(), integer()) :: t()
  def advance_level(%__MODULE__{tournament: nil} = state, _now), do: state

  def advance_level(%__MODULE__{tournament: tournament} = state, now) do
    next = tournament.level + 1

    # Отсчёт нового уровня идёт от дедлайна прошлого, а не от «сейчас»:
    # раздача могла затянуться, и считать от момента её конца значило бы
    # дарить турниру лишнее время на каждом повышении. Расписание обязано
    # держаться реального времени, а не суммы задержек.
    from = tournament.level_deadline_at || now

    %{
      state
      | tournament: %{
          tournament
          | level: next,
            level_deadline_at: level_deadline(tournament.levels, next, from)
        }
    }
  end

  @doc "Назначает дедлайн повышения для текущего уровня — от него турнир и стартует."
  @spec arm_level(t(), integer()) :: t()
  def arm_level(%__MODULE__{tournament: nil} = state, _now), do: state

  def arm_level(%__MODULE__{tournament: tournament} = state, now) do
    deadline = level_deadline(tournament.levels, tournament.level, now)

    %{state | tournament: %{tournament | level_deadline_at: deadline}}
  end

  @doc "Кладёт выпавший приз. Тянется один раз, до первой раздачи."
  @spec put_prize(t(), prize()) :: t()
  def put_prize(%__MODULE__{tournament: nil} = state, _prize), do: state

  def put_prize(%__MODULE__{tournament: tournament} = state, prize),
    do: %{state | tournament: %{tournament | prize: prize}}

  @doc """
  Фиксирует вылет: игрок занимает место с указанным номером.

  Номер приходит снаружи, а не считается здесь: вылететь в одной раздаче
  могут двое сразу, и тогда места между ними делит режим — по стеку на
  начало раздачи, а не по порядку обхода мест.
  """
  @spec eliminate(t(), Seat.t(), pos_integer()) :: t()
  def eliminate(%__MODULE__{tournament: nil} = state, _seat, _place), do: state

  def eliminate(%__MODULE__{tournament: tournament} = state, %Seat{} = seat, place) do
    entry = %{seat: seat.number, user_id: seat.user_id, place: place}

    %{state | tournament: %{tournament | standings: [entry | tournament.standings]}}
  end

  @doc "Сколько игроков ещё в турнире: место занято и стек не нулевой."
  @spec alive_count(t()) :: non_neg_integer()
  def alive_count(%__MODULE__{} = state) do
    state |> players() |> Enum.count(&(&1.stack > 0))
  end

  defp level_deadline(levels, number, now) do
    if BlindSchedule.next?(levels, number) do
      now + BlindSchedule.duration_ms(levels, number)
    end
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

  @doc """
  Стартует ли стол сам. `false` — первую раздачу запускает администратор
  командой `start_game`; дальше раздачи идут обычным порядком.
  """
  @spec auto_start?(t()) :: boolean()
  def auto_start?(%__MODULE__{mode: mode} = state), do: mode.auto_start?(state)

  @doc """
  Ждёт ли стол ручного запуска: игра ещё не начата, а сам он не начнётся.
  """
  @spec awaiting_manual_start?(t()) :: boolean()
  def awaiting_manual_start?(%__MODULE__{} = state),
    do: not auto_start?(state) and not state.game_started?

  @doc """
  Может ли игрок запустить стол руками. Обычному игроку — никогда, даже за
  столом без автостарта; администратору — пока стол ждёт запуска. Начатую
  игру запускать больше не надо, поэтому флаг гаснет вместе с ожиданием.
  """
  @spec can_start_manual?(t(), Ecto.UUID.t()) :: boolean()
  def can_start_manual?(%__MODULE__{} = state, user_id) do
    case find_seat(state, user_id) do
      nil -> false
      seat -> Seat.admin?(seat) and awaiting_manual_start?(state)
    end
  end

  @doc """
  Проверка команды ручного запуска: кто просит и в том ли стол состоянии.
  Собственно старт — дело `TableServer`, здесь только правило.
  """
  @spec validate_manual_start(t(), Ecto.UUID.t()) ::
          :ok | {:error, :not_seated | :start_not_available}
  def validate_manual_start(%__MODULE__{} = state, user_id) do
    cond do
      find_seat(state, user_id) == nil -> {:error, :not_seated}
      not can_start_manual?(state, user_id) -> {:error, :start_not_available}
      length(players(state)) < 2 -> {:error, :start_not_available}
      true -> :ok
    end
  end

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
  «Не ждать большого блайнда»: игрок готов заплатить за вход вне очереди.

  Сохраняется **намерение**, а не решение. Во что вход обойдётся — живой
  взнос, мёртвый или ничего, — зависит от того, где к началу раздачи будет
  кнопка; между нажатием и стартом она успевает сдвинуться, поэтому решение
  принимается в `resolve_post_intents/1`, а не здесь.
  """
  @spec request_post(t(), Ecto.UUID.t(), boolean()) :: {:ok, t(), Seat.t()} | {:error, atom()}
  def request_post(%__MODULE__{} = state, user_id, wanted?) do
    with {:ok, seat} <- fetch_player(state, user_id),
         :ok <- ensure_can_post(seat, wanted?) do
      seat = %{seat | wants_post: wanted?}
      {:ok, put_seat(state, seat), seat}
    end
  end

  # Ждать нечего тому, кто и так играет: кнопка «не ждать» для него бессмысленна.
  defp ensure_can_post(_seat, false), do: :ok

  defp ensure_can_post(%Seat{} = seat, true) do
    cond do
      not (seat.waiting_for_bb or seat.post_required) -> {:error, :post_not_available}
      not seat.can_post -> {:error, :post_not_available}
      true -> :ok
    end
  end

  @doc """
  Превратить намерения в решения — перед стартом раздачи и только там.

  Кнопка к этому моменту уже на своём месте, поэтому и живой взнос, и
  мёртвый считаются по той обстановке, в которой раздача действительно
  начнётся.
  """
  @spec resolve_post_intents(t()) :: t()
  def resolve_post_intents(%__MODULE__{} = state) do
    state
    |> seats()
    |> Enum.filter(&(&1.wants_post and (&1.waiting_for_bb or &1.post_required)))
    |> Enum.reduce(state, &resolve_post_intent(&2, &1))
  end

  defp resolve_post_intent(state, seat) do
    decision = entry_decision(state, seat, :post)

    if decision.status == :playing do
      put_seat(state, %{
        seat
        | waiting_for_bb: false,
          post_required: false,
          wants_post: false,
          post: decision.post,
          dead_post: decision.dead_post
      })
    else
      state
    end
  end

  @doc "Взнос сыгран: раздача его забрала, на следующую он не переносится."
  @spec clear_posts(t(), [pos_integer()]) :: t()
  def clear_posts(%__MODULE__{} = state, seat_numbers) do
    Enum.reduce(seat_numbers, state, fn number, acc ->
      case Map.get(acc.seats, number) do
        nil -> acc
        seat -> put_seat(acc, %{seat | post: 0, dead_post: 0})
      end
    end)
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

  @doc """
  Объявить страддл или снять объявление. `nil` — режим выключен.

  Сумма приводится к допустимой сразу (`Engine.Straddle`): игрок не должен
  узнавать о том, что 100 BB при стеке в 40 — это олл-ин, в момент раздачи.
  """
  @spec set_straddle(t(), Ecto.UUID.t(), pos_integer() | nil) ::
          {:ok, t(), Seat.t()} | {:error, atom()}
  def set_straddle(%__MODULE__{} = state, user_id, nil) do
    with {:ok, seat} <- fetch_player(state, user_id) do
      seat = %{seat | straddle: nil}
      {:ok, put_seat(state, seat), seat}
    end
  end

  def set_straddle(%__MODULE__{} = state, user_id, amount) do
    with {:ok, seat} <- fetch_player(state, user_id),
         :ok <- ensure_straddle_allowed(state),
         {:ok, amount} <- Straddle.normalize(amount, bet_unit(state), seat.stack) do
      seat = %{seat | straddle: amount}
      {:ok, put_seat(state, seat), seat}
    end
  end

  defp ensure_straddle_allowed(%__MODULE__{straddle_allowed?: true}), do: :ok
  defp ensure_straddle_allowed(_state), do: {:error, :straddle_unavailable}

  @doc """
  Заявки на страддл среди мест, которые эту раздачу играют.

  Возвращаются уже урезанные по стеку: объявление живёт дольше раздачи,
  а стек между ними меняется. Место, которому на страддл уже не хватает,
  из списка выпадает молча — объявление при этом сохраняется, чтобы после
  докупки не пришлось ставить галочку заново.
  """
  @spec straddle_intents(t(), [pos_integer()]) :: [Straddle.intent()]
  def straddle_intents(%__MODULE__{straddle_allowed?: false}, _seats), do: []

  def straddle_intents(%__MODULE__{} = state, seats) do
    unit = bet_unit(state)

    seats
    |> Enum.map(&Map.get(state.seats, &1))
    |> Enum.reject(&(&1 == nil or &1.straddle == nil))
    |> Enum.flat_map(fn seat ->
      case Straddle.normalize(seat.straddle, unit, seat.stack) do
        {:ok, amount} -> [%{seat: seat.number, amount: amount}]
        {:error, _reason} -> []
      end
    end)
  end

  @doc "Открыть окно объявления суммы: до этого момента раздача не стартует."
  @spec open_straddle_window(t(), integer()) :: t()
  def open_straddle_window(%__MODULE__{} = state, deadline_at) do
    %{state | phase: :straddle, straddle_deadline_at: deadline_at}
  end

  @doc "Окно закрылось: суммы объявлены, раздача может начинаться."
  @spec close_straddle_window(t()) :: t()
  def close_straddle_window(%__MODULE__{} = state) do
    %{state | phase: :idle, straddle_deadline_at: nil, straddle_done?: true}
  end

  @doc """
  Решение по бомб-поту принято: `nil` — раздача обычная. Помечается и то,
  и другое, потому что важен сам факт броска, а не его исход.
  """
  @spec put_bomb_pot(t(), BombPot.t() | nil) :: t()
  def put_bomb_pot(%__MODULE__{} = state, bomb_pot) do
    %{state | bomb_pot: bomb_pot, bomb_pot_rolled?: true}
  end

  @doc "Раздача кончилась: следующей нужен свой бросок."
  @spec reset_bomb_pot(t()) :: t()
  def reset_bomb_pot(%__MODULE__{} = state) do
    %{state | bomb_pot: nil, bomb_pot_rolled?: false}
  end

  @doc "Раздача началась или кончилась — окно следующей ещё не проводилось."
  @spec reset_straddle_window(t()) :: t()
  def reset_straddle_window(%__MODULE__{} = state) do
    %{state | straddle_deadline_at: nil, straddle_done?: false}
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

  @doc """
  Пополнить банки сыгравшим раздачу — до потолка шаблона.

  `owners` — кто сидел на месте, когда раздача начиналась: пополнение
  принадлежит игроку, а не креслу, и севшему следом не достаётся.
  """
  @spec refill_time_banks(t(), %{pos_integer() => Ecto.UUID.t()}) :: t()
  def refill_time_banks(%__MODULE__{} = state, owners) do
    amount = state.setting.time_bank_refill
    max = state.setting.time_bank_ms

    Enum.reduce(owners, state, fn {number, user_id}, acc ->
      case Map.get(acc.seats, number) do
        %Seat{user_id: ^user_id} = seat when user_id != nil ->
          put_seat(acc, %{seat | time_bank: TimeBank.refill(seat.time_bank, amount, max)})

        _other ->
          acc
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
      # Ник и косметика кладутся в само сообщение, а не берутся из места:
      # автор успевает встать из-за стола, а его реплика остаётся в истории.
      message = %{
        seat: seat.number,
        user_id: user_id,
        name: seat.name,
        flair: seat.flair,
        text: sanitized,
        at: at
      }

      state = put_seat(state, %{seat | chat_sent_at: sent_at})
      {:ok, %{state | chat: Chat.push(state.chat, message)}, message}
    end
  end

  @doc """
  Реакция за столом: проверка кулдауна и событие для броадкаста.

  Слать может любой занявший место — по тому же правилу, что и чат: реакция
  всплывает над аватаром, а у наблюдателя аватара за столом нет. Ни в
  историю, ни в снапшот она не попадает: реакция — жест, а не сообщение,
  и подключившийся не должен получать пачку чужих смайликов залпом.
  """
  @spec push_reaction(t(), Ecto.UUID.t(), term(), integer(), DateTime.t()) ::
          {:ok, t(), Reactions.event()} | {:error, atom() | {atom(), pos_integer()}}
  def push_reaction(%__MODULE__{} = state, user_id, id, now, at) do
    with {:ok, seat} <- fetch_player(state, user_id),
         {:ok, id} <- Reactions.fetch(id),
         {:ok, reacted_at} <- Reactions.throttle(seat.reacted_at, now) do
      event = %{seat: seat.number, user_id: user_id, id: id, at: at}
      {:ok, put_seat(state, %{seat | reacted_at: reacted_at}), event}
    end
  end

  @doc "Может ли игрок слать реакции — тем же правилом, что и решает `push_reaction/5`."
  @spec can_react?(t(), Ecto.UUID.t()) :: boolean()
  def can_react?(%__MODULE__{} = state, user_id) do
    match?({:ok, _seat}, fetch_player(state, user_id))
  end

  @doc """
  Что игрок видит про предложение сыграть дважды: кого спрашивают и сколько
  осталось времени. `nil` — вопроса нет.

  Кого спрашивают, решает раздача, а не комната: список мест берётся из
  `Engine.RunItTwice`, а не пересобирается здесь.
  """
  @spec run_it_twice_view(t(), integer()) :: map() | nil
  def run_it_twice_view(%__MODULE__{hand: nil}, _now), do: nil

  def run_it_twice_view(%__MODULE__{hand: hand} = state, now) do
    case Discipline.optional(state.discipline, :offer_view, [hand], nil) do
      nil -> nil
      offer -> Map.put(offer, :deadline_ms, max((state.rit_deadline_at || now) - now, 0))
    end
  end

  @doc """
  Заложить окно показа карт на паузу между раздачами.

  Что уже открылось на вскрытии, комната знает из самой раздачи: такие
  места попадают в окно с полностью открытыми картами, и кнопки показа у
  них не будет — показывать нечего.
  """
  @spec put_reveal(t(), term(), integer()) :: t()
  def put_reveal(%__MODULE__{} = state, hand, expires_at) do
    cards = Discipline.optional(state.discipline, :hole_cards, [hand], %{})
    decision = Discipline.optional(state.discipline, :reveal_decision, [hand], %{})
    owners = state.discipline.players(hand)

    reveal = %{
      cards: Map.new(cards, fn {seat, hole} -> {seat, Enum.map(hole, &Card.to_map/1)} end),
      users: Map.new(cards, fn {seat, _hole} -> {seat, owners[seat].id} end),
      shown:
        Map.new(cards, fn {seat, hole} ->
          open =
            if Map.get(decision, seat) == :show, do: Enum.to_list(0..(length(hole) - 1)), else: []

          {seat, open}
        end),
      expires_at: expires_at
    }

    %{state | reveal: reveal}
  end

  @doc """
  Разложить по местам то, что они уносят в следующую раздачу.

  Комната не знает, что это за значение: ей приходит готовая карта
  «место → что унести», и она её раскладывает. Что туда класть, решает
  режим — тому, кто отвечает за происходящее **между** раздачами, такой
  перенос и принадлежит.
  """
  @spec put_carry(t(), %{pos_integer() => term()}) :: t()
  def put_carry(%__MODULE__{} = state, carry) when is_map(carry) do
    seats =
      Enum.reduce(carry, state.seats, fn {number, value}, seats ->
        case Map.get(seats, number) do
          nil -> seats
          seat -> Map.put(seats, number, %{seat | carry: value})
        end
      end)

    %{state | seats: seats}
  end

  @spec clear_reveal(t()) :: t()
  def clear_reveal(%__MODULE__{} = state), do: %{state | reveal: nil}

  @doc """
  Показать столу свои карты прошедшей раздачи.

  Право проверяется **здесь**: показать можно только свои карты, только
  сидя за столом и только пока идёт пауза после раздачи. Во время раздачи
  показ запрещён — открытая карта сбросившего это подсказка тем, кто ещё
  торгуется, и в живом покере за неё наказывают.

  `indexes` — какие именно карты открыть. Повтор идемпотентен: уже
  открытая карта второй раз ничего не меняет и события не порождает.
  """
  @spec show_cards(t(), Ecto.UUID.t(), [non_neg_integer()] | :all, integer()) ::
          {:ok, t(), map()} | {:error, atom()}
  def show_cards(%__MODULE__{} = state, user_id, indexes, now) do
    with {:ok, _seat} <- fetch_player(state, user_id),
         {:ok, reveal} <- fetch_reveal(state, now),
         {:ok, seat_number} <- reveal_seat(reveal, user_id) do
      hole = Map.fetch!(reveal.cards, seat_number)
      open = Map.fetch!(reveal.shown, seat_number)
      wanted = wanted_indexes(indexes, hole)

      case Enum.sort(Enum.uniq(open ++ wanted)) do
        ^open ->
          {:error, :already_shown}

        shown ->
          reveal = %{reveal | shown: Map.put(reveal.shown, seat_number, shown)}
          {:ok, %{state | reveal: reveal}, shown_payload(seat_number, hole, shown)}
      end
    end
  end

  @doc """
  Что стол видит из добровольно открытых карт: место и его карты, где
  закрытая карта — `nil`. Пустой список, если окна нет.

  Нужно не только событием: подключившийся в паузу игрок обязан увидеть
  уже открытые карты, а не пустой стол.
  """
  @spec revealed(t(), integer()) :: [map()]
  def revealed(%__MODULE__{} = state, now) do
    case fetch_reveal(state, now) do
      {:ok, reveal} ->
        reveal.shown
        |> Enum.reject(fn {_seat, shown} -> shown == [] end)
        |> Enum.sort_by(fn {seat, _shown} -> seat end)
        |> Enum.map(fn {seat, shown} ->
          shown_payload(seat, Map.fetch!(reveal.cards, seat), shown)
        end)

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Разбор своей руки для окна-калькулятора. `nil` — раздачи нет, игрок не
  сидит за столом или карт у него в этой раздаче не было.

  Считается по картам самого игрока: наблюдателю и чужому месту здесь
  взяться неоткуда, как и в `hole_cards`.
  """
  @spec insight(t(), Ecto.UUID.t()) :: HandInsight.t() | nil
  def insight(%__MODULE__{hand: nil}, _user_id), do: nil

  def insight(%__MODULE__{hand: hand} = state, user_id) do
    case find_seat(state, user_id) do
      nil -> nil
      seat -> Discipline.optional(state.discipline, :insight, [hand, seat.number], nil)
    end
  end

  @doc """
  Что игрок видит про свой показ: какие карты ещё можно открыть и сколько
  осталось времени. `nil` — показывать нечего или окно закрыто.
  """
  @spec reveal_view(t(), Ecto.UUID.t(), integer()) :: map() | nil
  def reveal_view(%__MODULE__{} = state, user_id, now) do
    with {:ok, reveal} <- fetch_reveal(state, now),
         {:ok, seat_number} <- reveal_seat(reveal, user_id) do
      hole = Map.fetch!(reveal.cards, seat_number)
      shown = Map.fetch!(reveal.shown, seat_number)

      %{
        expires_ms: reveal.expires_at - now,
        cards: hole,
        shown: shown,
        hidden: Enum.reject(0..(length(hole) - 1), &(&1 in shown))
      }
    else
      _other -> nil
    end
  end

  defp wanted_indexes(:all, hole), do: Enum.to_list(0..(length(hole) - 1))

  defp wanted_indexes(indexes, hole) do
    Enum.filter(indexes, &(is_integer(&1) and &1 >= 0 and &1 < length(hole)))
  end

  defp shown_payload(seat, hole, shown) do
    cards = hole |> Enum.with_index() |> Enum.map(fn {card, i} -> if i in shown, do: card end)
    %{seat: seat, cards: cards}
  end

  defp reveal_seat(reveal, user_id) do
    case Enum.find(reveal.users, fn {_seat, id} -> id == user_id end) do
      {seat, _id} -> {:ok, seat}
      nil -> {:error, :not_a_contender}
    end
  end

  # Окно закрыто, если его нет, оно истекло или уже идёт следующая раздача.
  # Последнее — то самое правило, ради которого всё и проверяется: показ
  # своих карт посреди живой раздачи меняет решения тех, кто ещё в игре.
  defp fetch_reveal(%__MODULE__{hand: hand}, _now) when not is_nil(hand),
    do: {:error, :hand_in_progress}

  defp fetch_reveal(%__MODULE__{reveal: nil}, _now), do: {:error, :reveal_unavailable}

  defp fetch_reveal(%__MODULE__{reveal: reveal}, now) do
    if reveal.expires_at > now, do: {:ok, reveal}, else: {:error, :reveal_unavailable}
  end

  @doc """
  Заложить снимок rabbit hunting на паузу между раздачами.

  `runout` — уже посчитанные `Engine.Rabbit` карты, а не колода: комната
  хранит ровно то, что имеет право показать.
  """
  @spec put_rabbit(t(), [map()], integer()) :: t()
  def put_rabbit(%__MODULE__{} = state, runout, expires_at) do
    %{state | rabbit: %{runout: runout, expires_at: expires_at, revealed?: false}}
  end

  @spec clear_rabbit(t()) :: t()
  def clear_rabbit(%__MODULE__{} = state), do: %{state | rabbit: nil}

  @doc """
  Показать карты, которые пришли бы дальше.

  Право проверяется **здесь**: смотреть может только занявший место, и
  только пока идёт пауза после раздачи, законченной фолдом. Наблюдателю
  отказ — за столом он не сидит.

  Первый показ продлевает окно на `extra`: карты открылись всем сразу, и
  следующая раздача не должна стартовать раньше, чем их успели увидеть.
  Повторный запрос ничего не продлевает и новых карт не открывает — он
  идемпотентен, иначе нажатие «ещё раз» откладывало бы игру бесконечно.
  """
  @spec reveal_rabbit(t(), Ecto.UUID.t(), integer(), non_neg_integer()) ::
          {:ok, t(), [map()]} | {:revealed, [map()]} | {:error, atom()}
  def reveal_rabbit(%__MODULE__{} = state, user_id, now, extra) do
    with {:ok, _seat} <- fetch_player(state, user_id),
         {:ok, rabbit} <- fetch_rabbit(state, now) do
      if rabbit.revealed? do
        {:revealed, rabbit.runout}
      else
        rabbit = %{rabbit | revealed?: true, expires_at: rabbit.expires_at + extra}
        {:ok, %{state | rabbit: rabbit}, rabbit.runout}
      end
    end
  end

  @doc """
  Что игрок видит про rabbit hunting: доступна ли кнопка и открытые карты.

  Возвращается только сидящему — вызывается из личной части снапшота.
  """
  @spec rabbit_view(t(), integer()) :: map() | nil
  def rabbit_view(%__MODULE__{} = state, now) do
    case fetch_rabbit(state, now) do
      {:ok, rabbit} ->
        %{
          available: not rabbit.revealed?,
          expires_ms: rabbit.expires_at - now,
          cards: if(rabbit.revealed?, do: rabbit.runout)
        }

      {:error, _reason} ->
        nil
    end
  end

  # Окно закрыто, если снимка нет, оно истекло или раздача уже идёт:
  # во время раздачи показывать «что будет дальше» нельзя ни при каких
  # обстоятельствах — это и есть та дырка, ради которой всё проверяется.
  defp fetch_rabbit(%__MODULE__{rabbit: nil}, _now), do: {:error, :rabbit_unavailable}

  defp fetch_rabbit(%__MODULE__{hand: hand}, _now) when not is_nil(hand),
    do: {:error, :rabbit_unavailable}

  defp fetch_rabbit(%__MODULE__{rabbit: rabbit}, now) do
    if now < rabbit.expires_at, do: {:ok, rabbit}, else: {:error, :rabbit_unavailable}
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

  @doc """
  Участвует ли место в **идущей** раздаче, то есть претендует ли на банк.

  Считается по раздаче, а не по стеку места: у игрока в олл-ине стек равен
  нулю, но банк он разыгрывает наравне со всеми, и уйти из-за стола в этот
  момент значило бы подарить свой выигрыш пустому месту. Сброшенная рука
  на банк не претендует — такому игроку уходить можно.
  """
  @spec in_hand?(t(), pos_integer()) :: boolean()
  def in_hand?(%__MODULE__{hand: nil}, _seat_number), do: false

  def in_hand?(%__MODULE__{hand: hand}, seat_number) do
    case Map.get(hand.players, seat_number) do
      nil -> false
      player -> player.status != :folded
    end
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
          avatar: Map.get(profile, :avatar),
          flair: Map.get(profile, :flair),
          role: Map.get(profile, :role, :default)
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
            can_post: decision.can_post,
            post: decision.post,
            dead_post: decision.dead_post
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
    policy = state.mode.entry_policy(state)

    entry_rules(state).decide(%{
      seat: seat.number,
      intent: intent,
      seats_in_game: state |> players() |> Enum.map(& &1.number),
      button_seat: state.button_seat,
      big_blind_seat: state.big_blind_seat,
      big_blind: policy.big_blind,
      heads_up?: heads_up?(state),
      allow_post_blind?: policy.allow_post_blind?,
      missed_blinds: seat.missed_blinds,
      dodging?: dodging?(state, seat.user_id)
    })
  end

  @doc """
  Базовая единица стола: от неё считаются минимальная ставка и категория
  лимита. На блайндовом столе это большой блайнд, на анте-столе — анте.

  Величину даёт режим, а не комната: в кэше номиналы неизменны и лежат
  в шаблоне, в турнире они растут и приходят из текущего уровня структуры.
  Выбирать между полями шаблона прямо здесь значило бы ветвиться по
  правилам игры.
  """
  @spec bet_unit(t()) :: non_neg_integer()
  def bet_unit(%__MODULE__{mode: mode} = state), do: mode.bet_unit(state)

  @doc """
  Допустима ли такая сумма фишек на столе с учётом уже лежащего перед
  игроком стека.

  Границы задаёт режим, а не комната: в кэше это `min_buy_in` / `max_buy_in`
  шаблона, в турнире — стартовый стек и ничто другое. Почему проверяется
  итоговый стек, а не сумма операции, объяснено там же, в реализациях.
  """
  @spec validate_buy_in(t(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, :invalid_buy_in}
  def validate_buy_in(state, amount, current_stack \\ 0) do
    state.mode.validate_buy_in(state, amount, current_stack)
  end

  @doc """
  Начало докупки: проверка условий и **закрепление ключа** за местом.

  Раздача докупку не запрещает: заказать её можно в любой момент, а лягут
  фишки на стол в начале следующей раздачи (`queue_add_chips/3`). Ловить
  паузу между раздачами игрок не обязан — это требование от него ничего
  не защищало, кроме эффективного стека посреди торговли, а его защищает
  сам факт отложенного зачисления.

  Ключ живёт в месте, а не выдаётся заново на каждый вызов, потому что между
  проверкой и зачислением лежит поход в кошелёк. Двойной клик по «докупить»
  успевает пройти проверку дважды **до** первого зачисления — с новым ключом
  на каждый вызов это два списания подряд. Пока докупка не зачислена, повтор
  на ту же сумму получает тот же ключ: кошелёк по нему уже списал и второй
  раз не спишет.

  Другая сумма поверх незавершённой докупки — не повтор, а второй запрос, и
  он отклоняется: какая из двух сумм окажется на столе, иначе решала бы гонка.
  Поверх **отложенной** докупки та же сумма, наоборот, разрешена и заменяет
  её: заявка ещё не сработала, менять её игрок вправе. Заменённая заявка
  возвращается третьим элементом ответа — деньги по ней вернёт вызывающий.
  """
  @spec begin_add_chips(t(), Ecto.UUID.t(), pos_integer(), String.t()) ::
          {:ok, t(), String.t(), %{ref: String.t(), amount: pos_integer()} | nil}
          | {:error, atom()}
  def begin_add_chips(state, user_id, amount, ref) do
    with {:ok, seat} <- fetch_player(state, user_id),
         {:ok, ref, replaced} <- reuse_ref(seat, amount, ref),
         :ok <- validate_buy_in(state, amount, seat.stack) do
      seat = %{seat | add_chips: %{ref: ref, amount: amount, status: :pending}}
      {:ok, put_seat(state, seat), ref, replaced}
    end
  end

  defp reuse_ref(%Seat{add_chips: %{status: status, amount: amount, ref: ref}}, amount, _new)
       when status in [:pending, :queued],
       do: {:ok, ref, nil}

  # Ждущая своей раздачи докупка — это ещё не решение, а заявка, и другая
  # сумма её заменяет: игрок передумал, а не заказал вторую. Списанное по
  # старой заявке возвращает вызывающий — она названа в `replaced`.
  defp reuse_ref(%Seat{add_chips: %{status: :queued} = old}, _amount, ref),
    do: {:ok, ref, %{ref: old.ref, amount: old.amount}}

  # А вот незавершённая докупка на другую сумму — гонка: деньги по ней прямо
  # сейчас идут через кошелёк, и какая из двух сумм окажется на столе,
  # решал бы порядок ответов.
  defp reuse_ref(%Seat{add_chips: %{status: :pending}}, _amount, _new),
    do: {:error, :add_chips_in_progress}

  defp reuse_ref(%Seat{}, _amount, ref), do: {:ok, ref, nil}

  @doc """
  Зачисление докупки. Между раздачами фишки ложатся на стол сразу; во время
  раздачи докупка встаёт в очередь и зачисляется в начале следующей
  (`apply_queued_add_chips/1`).

  Сумма берётся из закреплённого ключа, а не из аргумента: зачисляется ровно
  то, что было списано. Повтор по уже зачисленному ключу — `:already_credited`,
  а не второе зачисление и не ошибка: деньги по нему на столе, и возвращать
  их вызывающему нечего.
  """
  @spec commit_add_chips(t(), Ecto.UUID.t(), String.t()) ::
          {:ok, t(), Seat.t()}
          | {:queued, t(), Seat.t(), pos_integer()}
          | {:already_credited, Seat.t()}
          | {:error, atom()}
  def commit_add_chips(state, user_id, ref) do
    with {:ok, seat} <- fetch_player(state, user_id) do
      case seat.add_chips do
        %{ref: ^ref, status: :pending, amount: amount} -> settle(state, seat, ref, amount)
        %{ref: ^ref, status: :queued} = queued -> {:queued, state, seat, queued.amount}
        %{ref: ^ref, status: :settled} -> {:already_credited, seat}
        _other -> {:error, :add_chips_lost}
      end
    end
  end

  # Идёт раздача — фишки на стол не падают: эффективный стек посреди торговли
  # обесценил бы уже сделанные ставки. Деньги при этом уже списаны, поэтому
  # докупка не отклоняется, а встаёт в очередь до начала следующей раздачи.
  defp settle(%__MODULE__{phase: :hand} = state, seat, ref, amount) do
    seat = %{seat | add_chips: %{ref: ref, amount: amount, status: :queued}}
    {:queued, put_seat(state, seat), seat, amount}
  end

  defp settle(state, seat, ref, amount), do: credit(state, seat, ref, amount)

  # Условия проверяются заново: пока деньги шли через кошелёк, стек за столом
  # успевает измениться. Отказ здесь — это уже списанные фишки, и возвращает
  # их вызывающий (`Tables.commit_add_chips/5`).
  defp credit(state, seat, ref, amount) do
    with :ok <- validate_buy_in(state, amount, seat.stack) do
      seat = %{
        seat
        | stack: seat.stack + amount,
          add_chips: %{ref: ref, amount: amount, status: :settled}
      }

      seat =
        if seat.stack > 0 and seat.status == :sitting_out,
          do: activate_seat(seat, state),
          else: seat

      {:ok, put_seat(state, seat), seat}
    end
  end

  @doc """
  Докупка не состоялась: ключ снимается с места, чтобы следующая попытка
  не упёрлась в `:add_chips_in_progress`. Деньги к этому моменту уже
  возвращены в кошелёк вызывающим.
  """
  @spec abort_add_chips(t(), Ecto.UUID.t(), String.t()) :: t()
  def abort_add_chips(state, user_id, ref) do
    case find_seat(state, user_id) do
      %Seat{add_chips: %{ref: ^ref, status: :pending}} = seat ->
        put_seat(state, %{seat | add_chips: nil})

      _other ->
        state
    end
  end

  @doc """
  Заказанная, но ещё не зачисленная докупка этого места, либо `nil`.

  Публична: соперник, считающий эффективный стек, обязан знать, что через
  раздачу перед этим креслом будет больше фишек. Скрывать это — давать
  преимущество тому, кто докупился, а не тому, кто внимателен.
  """
  @spec queued_add_chips(Seat.t()) :: pos_integer() | nil
  def queued_add_chips(%Seat{add_chips: %{status: :queued, amount: amount}}), do: amount
  def queued_add_chips(%Seat{}), do: nil

  @doc """
  Зачислить все отложенные докупки. Вызывается первым шагом старта раздачи —
  до отбора играющих мест и до блайндов, чтобы обнулившийся и тут же
  докупившийся игрок не пропускал раздачу, которую он уже оплатил.

  Границы проверяются заново: пока заявка ждала, стек мог вырасти. Лишнее
  не отменяет докупку целиком (деньги-то списаны), а урезается — остаток
  возвращает вызывающий, он назван в списке возвратов.
  """
  @spec apply_queued_add_chips(t()) ::
          {t(),
           [
             %{
               user_id: Ecto.UUID.t(),
               seat: pos_integer(),
               credited: non_neg_integer(),
               refund: non_neg_integer(),
               ref: String.t()
             }
           ]}
  def apply_queued_add_chips(state) do
    state
    |> seats()
    |> Enum.filter(&(queued_add_chips(&1) != nil))
    |> Enum.reduce({state, []}, fn seat, {state, applied} ->
      %{ref: ref, amount: amount} = seat.add_chips
      credited = trim_add_chips(state, seat, amount)

      seat = %{seat | add_chips: %{ref: ref, amount: credited, status: :settled}}
      seat = %{seat | stack: seat.stack + credited}

      seat =
        if seat.stack > 0 and seat.status == :sitting_out,
          do: activate_seat(seat, state),
          else: seat

      entry = %{
        user_id: seat.user_id,
        seat: seat.number,
        credited: credited,
        refund: amount - credited,
        ref: ref
      }

      {put_seat(state, seat), [entry | applied]}
    end)
    |> then(fn {state, applied} -> {state, Enum.reverse(applied)} end)
  end

  defp trim_add_chips(state, seat, amount) do
    case state.mode.max_add_chips(state, seat.stack) do
      nil -> amount
      max -> min(amount, max)
    end
  end

  @doc """
  Отмена отложенной докупки: заявка снимается с места, а её сумму —
  списанную, но так и не легшую на стол — возвращает вызывающий.

  Отменить можно только заявку, ждущую следующей раздачи. Незавершённая
  докупка (`:pending`) в этот момент идёт через кошелёк, и отменять то,
  чем сейчас распоряжается другой шаг, значит устраивать гонку за деньги.
  """
  @spec cancel_add_chips(t(), Ecto.UUID.t()) ::
          {:ok, t(), String.t(), pos_integer()} | {:error, atom()}
  def cancel_add_chips(state, user_id) do
    with {:ok, seat} <- fetch_player(state, user_id) do
      case seat.add_chips do
        %{status: :queued, ref: ref, amount: amount} ->
          {:ok, put_seat(state, %{seat | add_chips: nil}), ref, amount}

        _other ->
          {:error, :no_queued_add_chips}
      end
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
      # Отложенная докупка уходит вместе с игроком: деньги по ней списаны,
      # а стол, который он покидает, их уже не получит. Отдельным возвратом
      # это делать нечего — cash-out и так вычисляет, сколько ему должны.
      stack = seat.stack + (queued_add_chips(seat) || 0)
      seat = %{seat | status: :leaving, stack: 0, reservation_id: ref, add_chips: nil}
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
  @spec cancel_leave(t(), String.t(), non_neg_integer(), integer()) :: t()
  def cancel_leave(state, ref, stack, deadline) do
    case Enum.find(seats(state), &(&1.reservation_id == ref)) do
      nil ->
        state

      seat ->
        seat = begin_sit_out(%{seat | stack: stack, reservation_id: nil}, deadline)
        put_seat(state, seat)
    end
  end

  @doc """
  Просьба уйти в паузу. Раздачу, в которой игрок уже получил карты, он
  обязан доиграть: пауза посреди торговли — это либо бесплатный фолд с
  сохранением вложенного, либо зависший стол, ждущий ушедшего.

  Критерий тот же, что у ухода из-за стола (`in_hand?/2`): сбросивший карты
  больше ничего столу не должен, и его пауза начинается сразу.

  Поэтому решение и его применение разнесены. `:pending` — решение принято,
  оно сработает по концу раздачи (`apply_pending_sit_outs/2`); `:applied` —
  игрок в раздаче не участвует, пауза начинается сразу.

  `deadline` — монотонный момент, после которого пауза перестаёт держать
  место. Считает его оболочка: срок берётся из шаблона комнаты, а часов у
  чистой структуры нет.
  """
  @spec request_sit_out(t(), Ecto.UUID.t(), integer()) ::
          {:ok, t(), :applied | :pending} | {:error, atom()}
  def request_sit_out(state, user_id, deadline) do
    with {:ok, seat} <- fetch_player(state, user_id) do
      cond do
        in_hand?(state, seat.number) ->
          {:ok, put_seat(state, %{seat | sit_out_pending: true}), :pending}

        seat.status == :sitting_out ->
          {:error, :already_sitting_out}

        true ->
          {:ok, put_seat(state, begin_sit_out(seat, deadline)), :applied}
      end
    end
  end

  @doc """
  Раздача кончилась: отложенные паузы становятся настоящими. Возвращает
  места, которые в паузу ушли, — их оболочке нужно взвести таймером и
  объявить столу.
  """
  @spec apply_pending_sit_outs(t(), integer()) :: {t(), [pos_integer()]}
  def apply_pending_sit_outs(state, deadline) do
    state
    |> seats()
    |> Enum.filter(& &1.sit_out_pending)
    |> Enum.reduce({state, []}, fn seat, {acc, numbers} ->
      {put_seat(acc, begin_sit_out(seat, deadline)), [seat.number | numbers]}
    end)
    |> then(fn {acc, numbers} -> {acc, Enum.sort(numbers)} end)
  end

  @doc """
  Возврат в игру. Снимает и уже начавшуюся паузу, и ещё не наступившую:
  передумавший в середине раздачи игрок остаётся играть, ничего не пропуская.
  """
  @spec sit_in(t(), Ecto.UUID.t()) :: {:ok, t()} | {:error, atom()}
  def sit_in(state, user_id) do
    with {:ok, seat} <- fetch_player(state, user_id) do
      cond do
        seat.status != :sitting_out and seat.sit_out_pending ->
          {:ok, put_seat(state, %{seat | sit_out_pending: false})}

        seat.stack == 0 ->
          {:error, :zero_stack}

        true ->
          {:ok, put_seat(state, activate_seat(seat, state))}
      end
    end
  end

  defp begin_sit_out(seat, deadline) do
    %{
      seat
      | status: :sitting_out,
        waiting_for_bb: false,
        sit_out_pending: false,
        sit_out_until: deadline
    }
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
  Дальше место держит обычный срок паузы — тот же, что у нажавшего «сит-аут»
  вручную: для стола разницы между «отошёл» и «отвалился» нет.
  """
  @spec expire_grace(t(), pos_integer(), integer()) :: t()
  def expire_grace(state, seat_number, deadline) do
    case Map.fetch(state.seats, seat_number) do
      {:ok, %Seat{status: :disconnected} = seat} ->
        put_seat(state, begin_sit_out(seat, deadline))

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
      draining?: state.draining?,
      # Началась ли игра. Пулу турниров этого достаточно, чтобы отличить
      # «идёт регистрация» от «уже играют»: свободных мест у стартовавшего
      # турнира не бывает, но занятость мест сохраняется и после вылетов.
      game_started?: state.game_started?
    }
  end

  @doc """
  Освобождает все места.

  Нужно доигранному турниру: вылетевшие остаются за столом зрителями, и
  без явной очистки комната никогда не опустеет, а значит и не закроется.
  Кэш-стол этого не делает никогда — там место освобождает только сам
  игрок.
  """
  @spec clear_seats(t()) :: t()
  def clear_seats(%__MODULE__{} = state) do
    seats = Map.new(state.seats, fn {number, _seat} -> {number, Seat.new(number)} end)

    %{state | seats: seats}
  end

  @spec bump_seq(t()) :: t()
  def bump_seq(state), do: %{state | action_seq: state.action_seq + 1}

  # Встал и сел обратно в ту же комнату внутри окна — право «ждать блайнда»
  # потеряно, иначе вся конструкция обходится циклом «встал — сел».
  defp dodging?(_state, nil), do: false

  defp dodging?(state, user_id) do
    case Map.fetch(state.recent_leavers, user_id) do
      {:ok, hands} ->
        state.hands_played - hands < state.mode.entry_policy(state).dodge_window_hands

      :error ->
        false
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
        sit_out_pending: false,
        sit_out_until: nil,
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

  # Место, с которого игрок уже встал, заморожено: его стек уехал в кошелёк
  # и подтверждения транзакции ещё нет. Любое действие в этом окне — докупка,
  # сит-аут, второй уход — работает с местом, которого через миг не будет,
  # а купленные в этот момент фишки исчезают вместе с ним.
  # Правила входа принадлежат структуре ставок: там, где платят все и каждую
  # раздачу, ждать нечего и взнос брать не за что.
  defp entry_rules(%__MODULE__{setting: setting}) do
    setting.game_type
    |> VariantRegistry.fetch!()
    |> then(& &1.betting_structure())
    |> then(& &1.entry_rules())
  end

  defp fetch_player(state, user_id) do
    case find_seat(state, user_id) do
      nil -> {:error, :not_seated}
      %Seat{status: :leaving} -> {:error, :leave_in_progress}
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
end
