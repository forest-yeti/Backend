defmodule BlockPoker.Tournaments.TournamentServer do
  @moduledoc """
  Процесс одного инстанса турнира: сущность **над** столами.

  Владеет тем, что столу знать неоткуда:

    * списком участников и их состоянием;
    * текущим уровнем и дедлайном следующего повышения;
    * рассадкой — какой игрок за каким столом и на каком месте;
    * порядком вылетов, то есть местами, и призовым фондом;
    * перерывами.

  **Не владеет ходом раздачи.** Раздача целиком у `TableServer`, как и
  в кэше: турнир узнаёт о ней постфактум, событием `hand_finished`.

  ## Почему уровень — свойство турнира, а не стола

  Иначе столы разъехались бы: на медленном идёт третий уровень, на
  быстром пятый, и цена круга зависела бы от того, куда игрока посадили.
  Поэтому таймер один на весь турнир, а столам рассылается «уровень
  такой-то». Стол применяет его **со следующей раздачи** — повышение
  посреди улицы поменяло бы цену уже принятого решения. Отсюда следствие,
  которое выглядит багом, но им не является: несколько секунд разные
  столы играют на разных уровнях.

  ## Часы инжектируются

  Все турнирные таймеры **монотонны и паузятся**: на перерыве уровень не
  тикает, и каждый уровень честно получает своё игровое время. Абсолютный
  дедлайн этого бы не дал — он продолжал бы идти, пока никто не играет.

  Поэтому здесь два источника времени, и оба приходят снаружи:
  `monotonic` для длительностей и `wall` для стенных часов (перерыв
  привязан к `XX:55`, а не к старту турнира). В тестах оба подменяются,
  и `Process.sleep` не нужен (§11 CLAUDE.md).
  """

  use GenServer

  require Logger

  alias BlockPoker.Engine.{
    BlindSchedule,
    Bounty,
    Elimination,
    Seating,
    TournamentBreak,
    TournamentPayout
  }

  alias BlockPoker.History
  alias BlockPoker.Tables.{RoomState, TableRegistry, TableServer, TableSupervisor}
  alias BlockPoker.Tournaments
  alias BlockPoker.Tournaments.{TableSetting, Tournament}
  alias Phoenix.PubSub

  @pubsub BlockPoker.PubSub

  # Сколько стол ещё стоит после итога, прежде чем `TableSupervisor` его
  # остановит. Как в Sit & Go (`TableServer.maybe_settle/1`): игрок должен
  # успеть увидеть результат в своём канале, а не наткнуться на тишину.
  @tables_close_ms 15_000

  defmodule Player do
    @moduledoc """
    Участник глазами турнира: вход, место за столом и цена головы.

    `entry_id` здесь важнее `user_id`: голова, номер входа и место
    принадлежат **входу**, а игрок за турнир может войти несколько раз.
    """

    @enforce_keys [:entry_id, :user_id, :stack]
    defstruct [:entry_id, :user_id, :stack, :table_id, :seat, bounty: 0, alive?: true]
  end

  defmodule State do
    @moduledoc false

    @enforce_keys [:tournament_id, :setting, :snapshot, :monotonic, :wall]
    defstruct [
      :tournament_id,
      :setting,
      :snapshot,
      :monotonic,
      :wall,
      # Опции, с которыми поднимаются столы турнира. Существуют ради
      # тестов: там таймеры прогоняются вручную, а не реальным временем
      # (§11 CLAUDE.md).
      room_opts: [],
      # `%{entry_id => Player.t()}`
      players: %{},
      # `%{table_id => pid}` — столы, которые турнир поднял и держит.
      tables: %{},
      level: 1,
      # Сколько игрового времени уровня уже прошло (мс). Копится, а не
      # сравнивается с абсолютным дедлайном: на перерыве счёт стоит.
      level_elapsed_ms: 0,
      # Момент последнего запуска отсчёта уровня (монотонные мс) либо
      # `nil`, если уровень сейчас на паузе.
      level_started_at: nil,
      level_timer: nil,
      # Перерыв: `nil` — играем; `%{waiting: MapSet, ends_at}`.
      break: nil,
      break_timer: nil,
      # Hand-for-hand на баббле: `nil` — обычная игра;
      # `%{waiting: MapSet}` — идёт синхронный круг.
      hand_for_hand: nil,
      # Вылеты, по которым идёт окно ре-энтри: место зарезервировано,
      # но ещё не присвоено. `%{entry_id => %{place, user_id, timer}}`.
      pending_reentries: %{},
      status: :registering,
      # Конец позднего входа стенными часами — то же значение, что
      # проставлено на инстансе и что видит клиент (`LobbyEntry`).
      # Считается один раз на старте и дальше не двигается: см.
      # `late_reg_open?/1`.
      late_reg_until: nil,
      late_reg_timer: nil,
      # Места присваиваются с конца: первый вылетевший получает номер,
      # равный числу живых плюс один.
      results: [],
      final_table: nil,
      hands_played: 0
    ]
  end

  # --- Публичный API -------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    tournament_id = Keyword.fetch!(opts, :tournament_id)
    GenServer.start_link(__MODULE__, opts, name: via(tournament_id))
  end

  @doc """
  Адресация инстанса. Живёт в том же `Registry`, что и столы, но под
  своим ключом: единственное место, которое придётся менять при переходе
  на кластер (§8 CLAUDE.md).
  """
  @spec via(Ecto.UUID.t()) :: {:via, Registry, {module(), {:tournament, Ecto.UUID.t()}}}
  def via(tournament_id), do: {:via, Registry, {TableRegistry, {:tournament, tournament_id}}}

  @spec whereis(Ecto.UUID.t()) :: pid() | nil
  def whereis(tournament_id) do
    case Registry.lookup(TableRegistry, {:tournament, tournament_id}) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc "Снимок турнира: то, что видит игрок за столом и зритель в лобби."
  @spec state(Ecto.UUID.t() | pid()) :: map()
  def state(tournament), do: GenServer.call(server(tournament), :state)

  @doc """
  Запускает турнир: поднимает столы и рассаживает зарегистрированных.

  Вызывается по часам — планировщиком или таймером инстанса. Отдельной
  функцией, а не автоматикой в `init/1`, потому что момент старта решает
  время, а не факт поднятия процесса: инстанс живёт с открытия
  регистрации, то есть за час до первой карты.
  """
  @spec start_tournament(Ecto.UUID.t() | pid()) :: :ok | {:error, atom()}
  def start_tournament(tournament), do: GenServer.call(server(tournament), :start)

  @doc """
  Живые данные участников: стек, стол и место каждого входа.

  В снимок турнира этот список не входит и входить не будет (§5 задачи
  30): триста строк на каждый вылет каждому подписчику — квадратичный
  трафик. Здесь он отдаётся точечно, по запросу карточки: чипсчёт из БД
  знает про вход всё, кроме двух вещей — сколько у него фишек и за каким
  столом он сидит, а они живут только в процессе.
  """
  @spec players(Ecto.UUID.t() | pid()) :: [Player.t()]
  def players(tournament), do: GenServer.call(server(tournament), :players)

  @doc """
  Рассадка **до** старта: столы поднимаются и игроки садятся за минуту до
  начала, а раздача не идёт.

  Смысл — в окне стола у игрока. Пока рассадка случалась ровно в момент
  старта, окно стола открывалось после первой раздачи: игрок либо успевал
  нажать «Занять место», либо пропускал руку. Столы, поднятые заранее,
  стоят на паузе (`tournament_paused`) и ждут `start_tournament/1` — до
  него ни одна карта не сдаётся.

  Идемпотентна: повторный вызов на уже подготовленном турнире ничего не
  делает. Планировщик зовёт её каждый тик, и второго набора столов от
  этого появиться не должно.
  """
  @spec prepare(Ecto.UUID.t() | pid()) :: :ok | {:error, atom()}
  def prepare(tournament), do: GenServer.call(server(tournament), :prepare)

  @doc "Сажает вход за стол: поздняя регистрация и ре-энтри приходят сюда."
  @spec seat_entry(Ecto.UUID.t() | pid(), map()) :: :ok | {:error, atom()}
  def seat_entry(tournament, entry), do: GenServer.call(server(tournament), {:seat, entry})

  @doc """
  Убирает вход со стола: игрок отписался после подготовительной рассадки.

  Безвредна, если игрок ещё не сидит: до старта отписаться можно в любой
  момент, а сидит он или нет — знает только турнир.
  """
  @spec drop_entry(Ecto.UUID.t() | pid(), Ecto.UUID.t()) :: :ok
  def drop_entry(tournament, entry_id) do
    GenServer.call(server(tournament), {:drop_entry, entry_id})
  end

  @doc """
  Повторный вход после вылета: оплата и посадка одним вызовом.

  Идёт через процесс, а не прямо в контекст, потому что вход — это
  **и деньги, и место**: контекст знает про первое, рассадку знает
  только турнир. Разведи их по двум вызовам — и появится состояние,
  в котором игрок заплатил, но не сидит.
  """
  @spec reenter(Ecto.UUID.t() | pid(), Ecto.UUID.t()) :: {:ok, map()} | {:error, atom()}
  def reenter(tournament, user_id), do: GenServer.call(server(tournament), {:reenter, user_id})

  @doc """
  Аддон: фишки за деньги на перерыве.

  Тоже через процесс: право взять аддон зависит от уровня и от того,
  идёт ли перерыв, — а это знание турнира, не контекста.
  """
  @spec addon(Ecto.UUID.t() | pid(), Ecto.UUID.t()) :: {:ok, map()} | {:error, atom()}
  def addon(tournament, user_id), do: GenServer.call(server(tournament), {:addon, user_id})

  @doc "Прогон таймера вручную — для тестов на инжектированных часах."
  @spec fire(Ecto.UUID.t() | pid(), atom()) :: :ok
  def fire(tournament, timer), do: GenServer.call(server(tournament), {:fire, timer})

  defp server(pid) when is_pid(pid), do: pid
  defp server(tournament_id), do: via(tournament_id)

  # --- Жизненный цикл ------------------------------------------------------

  @impl true
  def init(opts) do
    tournament_id = Keyword.fetch!(opts, :tournament_id)

    with {:ok, tournament} <- Tournaments.get_tournament(tournament_id) do
      state = %State{
        tournament_id: tournament_id,
        setting: tournament.setting,
        snapshot: tournament.snapshot || %{},
        monotonic: Keyword.get(opts, :monotonic, fn -> System.monotonic_time(:millisecond) end),
        wall: Keyword.get(opts, :wall, &DateTime.utc_now/0),
        status: tournament.status
      }

      {:ok, restore(state, tournament)}
    end
  end

  # --- Восстановление ------------------------------------------------------

  # Процесс турнира перезапустился посреди игры.
  #
  # Это самое дорогое падение в системе, и оно не то же самое, что
  # падение стола: столы живут в своём супервизоре и раздают дальше, а
  # без турнира их никто не слушает — вылеты не считаются, места не
  # присваиваются, балансировки нет, и закончиться турнир не может уже
  # никогда. Пустой `players` означал бы именно это.
  #
  # Собирается состояние из двух источников, и разделение между ними —
  # не случайность: **всё, кроме рассадки и стеков, персистентно само по
  # себе.** Головы, статусы, места и окно входа лежат в `tournament_entries`
  # и `tournaments`; рассадка и стеки — только в снимке (`SeatSnapshot`),
  # ради чего он и пишется на каждой раздаче.
  #
  # Живой стол при этом важнее снимка: пока турнир лежал, стол продолжал
  # раздавать, и его стеки новее. Поэтому у поднявшихся столов состав
  # читается из самого стола, а снимок нужен только для тех, кто не пережил
  # падение вместе с турниром.
  defp restore(state, %Tournament{} = tournament) do
    if Tournament.live?(tournament) do
      do_restore(state, tournament)
    else
      state
    end
  end

  defp do_restore(state, tournament) do
    entries = Tournaments.list_seated(tournament.id)
    snapshot = seat_snapshot(tournament.id)

    Logger.warning(
      "турнир #{tournament.id}: восстановление после перезапуска — " <>
        "#{length(entries)} живых входов, уровень #{snapshot.level}"
    )

    state =
      %{
        state
        | level: snapshot.level,
          hands_played: snapshot.hands_played,
          late_reg_until: tournament.late_reg_until,
          results: restored_results(tournament.id)
      }
      |> adopt_tables(snapshot)
      |> restore_players(entries, snapshot)

    # Стол мог остаться на паузе — турнир упал на перерыве или посреди
    # круга hand-for-hand, а снять паузу было уже некому.
    resume_tables(state)

    state
    |> arm_level()
    |> arm_break()
    |> arm_late_reg()
    |> restore_final_table(tournament)
  end

  defp seat_snapshot(tournament_id) do
    case Tournaments.get_snapshot(tournament_id) do
      {:ok, snapshot} ->
        %{
          level: snapshot.level || 1,
          hands_played: snapshot.hands_played || 0,
          seats: snapshot.seats || []
        }

      {:error, :not_found} ->
        # Ни одной раздачи не сыграно: турнир упал между стартом и первой
        # рукой. Рассаживать придётся заново, и это законно — фишек ни у
        # кого ещё не двигалось.
        %{level: 1, hands_played: 0, seats: []}
    end
  end

  # Столы, пережившие падение турнира, подбираются как есть: подписка и
  # монитор заводятся заново, состав читается у самого стола.
  defp adopt_tables(state, snapshot) do
    snapshot.seats
    |> Enum.map(&Map.get(&1, "table"))
    |> Enum.uniq()
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(state, fn table_id, acc ->
      case TableRegistry.whereis(table_id) do
        nil ->
          acc

        pid ->
          :ok = PubSub.subscribe(@pubsub, TableServer.topic(table_id))
          Process.monitor(pid)

          %{acc | tables: Map.put(acc.tables, table_id, pid)}
      end
    end)
  end

  # Стек и место берутся у живого стола, а не из снимка: пока турнир
  # лежал, стол раздавал, и снимок отстал ровно на эти раздачи.
  defp restore_players(state, entries, snapshot) do
    live = live_seats(state)
    saved = Map.new(snapshot.seats, &{Map.get(&1, "entry_id"), &1})

    {seated, homeless} =
      Enum.reduce(entries, {%{}, []}, fn entry, {players, homeless} ->
        case restored_player(entry, live) do
          nil -> {players, [{entry, saved_stack(saved, entry)} | homeless]}
          player -> {Map.put(players, entry.id, player), homeless}
        end
      end)

    state = %{state | players: seated}

    # Вход без места: его стол не пережил падение вместе с турниром либо
    # он сел уже после последнего снимка. И тот и другой обязаны оказаться
    # за столом — иначе живой вход останется вне игры навсегда.
    #
    # Стек берётся из снимка, если он там был: садить со стартовым
    # значило бы напечатать фишки. Незавершённая раздача упавшего стола
    # при этом аннулируется — то же правило, что и в `recover_table/3`
    # (§8 CLAUDE.md).
    Enum.reduce(homeless, state, fn {entry, stack}, acc ->
      case place_player(
             acc,
             %{
               id: entry.id,
               user_id: entry.user_id,
               entry_number: entry.entry_number,
               bounty: entry.bounty
             },
             stack
           ) do
        {:ok, acc} ->
          acc

        {:error, reason} ->
          Logger.error(
            "турнир #{acc.tournament_id}: вход #{entry.id} не сел при восстановлении — " <>
              "#{inspect(reason)}"
          )

          acc
      end
    end)
  end

  defp saved_stack(saved, entry) do
    case Map.get(saved, entry.id) do
      %{"stack" => stack} when is_integer(stack) and stack > 0 -> stack
      _absent -> nil
    end
  end

  defp restored_player(entry, live) do
    cond do
      seat = Map.get(live, entry.user_id) ->
        %Player{
          entry_id: entry.id,
          user_id: entry.user_id,
          stack: seat.stack,
          table_id: seat.table_id,
          seat: seat.seat,
          bounty: entry.bounty
        }

      true ->
        nil
    end
  end

  defp live_seats(state) do
    Enum.reduce(state.tables, %{}, fn {table_id, pid}, acc ->
      pid
      |> TableServer.state()
      |> RoomState.players()
      |> Enum.reduce(acc, fn seat, seats ->
        Map.put(seats, seat.user_id, %{table_id: table_id, seat: seat.number, stack: seat.stack})
      end)
    end)
  end

  # Места вылетевших уже проставлены в БД — их и поднимаем: без них
  # расчёт турнира не соберёт таблицу.
  defp restored_results(tournament_id) do
    tournament_id
    |> Tournaments.list_entries()
    |> Enum.filter(&(&1.place != nil))
    |> Enum.sort_by(& &1.place)
    |> Enum.map(
      &%{entry_id: &1.id, place: &1.place, shared_places: &1.shared_places || [&1.place]}
    )
  end

  defp restore_final_table(state, %Tournament{status: :finishing} = _tournament) do
    case Map.keys(state.tables) do
      [table_id] -> %{state | final_table: table_id}
      _other -> state
    end
  end

  defp restore_final_table(state, _tournament), do: state

  @impl true
  def handle_call(:state, _from, state), do: {:reply, snapshot(state), state}

  def handle_call(:players, _from, state), do: {:reply, Map.values(state.players), state}

  def handle_call(:start, _from, %State{status: status} = state)
      when status in [:running, :late_reg_closed, :finishing, :finished] do
    {:reply, {:error, :tournament_started}, state}
  end

  def handle_call(:start, _from, state) do
    case Tournaments.get_tournament(state.tournament_id) do
      {:ok, tournament} -> do_start(state, tournament)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Подготовка не меняет статус инстанса в БД: турнир всё ещё
  # `registering`, регистрация открыта, отписаться можно (`drop_entry/2`
  # уберёт такого со стола).
  def handle_call(:prepare, _from, %State{status: status} = state)
      when status not in [:announced, :registering] do
    {:reply, {:error, :tournament_started}, state}
  end

  def handle_call(:prepare, _from, %State{tables: tables} = state) when map_size(tables) > 0 do
    {:reply, :ok, state}
  end

  def handle_call(:prepare, _from, state) do
    entries = Tournaments.list_seated(state.tournament_id)

    if length(entries) < state.setting.min_players do
      {:reply, {:error, :not_enough_players}, state}
    else
      state = state |> seat_all(entries) |> mark_seated_playing() |> pause_tables()

      broadcast(state, "tables_ready", %{tables: Map.keys(state.tables)})

      {:reply, :ok, state}
    end
  end

  # Снимает вход со стола: игрок отписался в последнюю минуту, когда
  # рассадка уже сделана. До старта это законно, и место обязано
  # освободиться — иначе за столом сидит игрок, которому вернули взнос.
  def handle_call({:drop_entry, entry_id}, _from, state) do
    case Map.fetch(state.players, entry_id) do
      {:ok, _player} ->
        state = release_seat(state, entry_id)

        {:reply, :ok, %{state | players: Map.delete(state.players, entry_id)}}

      :error ->
        {:reply, :ok, state}
    end
  end

  # Столов ещё нет — турнир не подготовлен и не стартовал. Сажать некуда,
  # и поднимать стол на одну регистрацию нельзя: стартовая рассадка
  # прочитает вход из БД и раздаст его вместе со всеми.
  def handle_call({:seat, _entry}, _from, %State{tables: tables} = state)
      when map_size(tables) == 0 do
    {:reply, :ok, state}
  end

  def handle_call({:seat, entry}, _from, state) do
    case seat_player(state, entry) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:reenter, user_id}, _from, state) do
    case do_reenter(state, user_id) do
      {:ok, entry, state} ->
        {:reply, {:ok, %{entry_id: entry.id, entry_number: entry.entry_number}}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:addon, user_id}, _from, state) do
    case do_addon(state, user_id) do
      {:ok, stack, state} -> {:reply, {:ok, %{stack: stack}}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:fire, :level}, _from, state) do
    {:reply, :ok, advance_level(state)}
  end

  def handle_call({:fire, :break}, _from, state) do
    {:reply, :ok, begin_break(state)}
  end

  def handle_call({:fire, :break_over}, _from, state) do
    {:reply, :ok, end_break(state)}
  end

  def handle_call({:fire, :late_reg}, _from, state) do
    {:reply, :ok, close_late_reg(state)}
  end

  @impl true
  def handle_info(:level_up, state), do: {:noreply, advance_level(state)}

  def handle_info(:break_due, state), do: {:noreply, begin_break(state)}

  def handle_info(:break_over, state), do: {:noreply, end_break(state)}

  # Истекло окно входа: вход и ребаи закрыты, фонд зафиксирован.
  def handle_info(:late_reg_over, state), do: {:noreply, close_late_reg(state)}

  # Пауза после итога вышла: столы, которые турнир ещё держит, можно
  # останавливать — победитель уже получил результат в свой канал.
  def handle_info(:close_finished_tables, state) do
    {:noreply, close_tables(state, Map.keys(state.tables))}
  end

  # Окно ре-энтри истекло: место присвоено, игрок в результатах.
  def handle_info({:reentry_expired, entry_id}, state) do
    case Map.fetch(state.pending_reentries, entry_id) do
      {:ok, pending} ->
        state = %{state | pending_reentries: Map.delete(state.pending_reentries, entry_id)}

        {:noreply, state |> finalize_bust(entry_id, pending.placement) |> maybe_finish()}

      :error ->
        {:noreply, state}
    end
  end

  # Раздача закончилась: это единственный момент, когда турнир вправе
  # что-то менять за столом — между раздачами. Здесь и вылеты, и головы,
  # и балансировка, и вход в перерыв.
  def handle_info({:table_event, "hand_summary", payload}, state) do
    {:noreply, on_hand_finished(state, payload)}
  end

  def handle_info({:table_event, _event, _payload}, state), do: {:noreply, state}

  def handle_info({:tournament_updated, _id}, state), do: {:noreply, state}

  # Стол упал. Комната не перезапускается сама (`restart: :temporary`),
  # и её падение — не повод терять турнир: рассадку и стеки турнир знает
  # сам, они у него в `players`.
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Enum.find(state.tables, fn {_id, table_pid} -> table_pid == pid end) do
      nil -> {:noreply, state}
      {table_id, _pid} -> {:noreply, recover_table(state, table_id, reason)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # --- Старт ---------------------------------------------------------------

  defp do_start(state, %Tournament{} = tournament) do
    entries = Tournaments.list_seated(tournament.id)

    if length(entries) < state.setting.min_players do
      {:reply, {:error, :not_enough_players}, state}
    else
      until = late_reg_until(state)
      {:ok, _tournament} = Tournaments.start(tournament, until)

      state =
        %{state | status: :running, late_reg_until: until}
        |> seat_prepared(entries)
        |> arm_level()
        |> arm_break()
        |> arm_late_reg()

      broadcast(state, "tournament_started", %{tables: Map.keys(state.tables)})

      {:reply, :ok, state}
    end
  end

  # Конец последнего ребайного уровня в абсолютном времени. Считается на
  # старте, потому что до него длительности уровней ещё ничего не значат:
  # турнир мог и не начаться.
  defp late_reg_until(state) do
    levels = TableSetting.levels(state.snapshot)
    flags = level_flags(state)

    seconds =
      levels
      |> Enum.filter(&Map.get(flags, &1.level, false))
      |> Enum.reduce(0, &(&2 + &1.duration_seconds))

    if seconds == 0, do: nil, else: DateTime.add(state.wall.(), seconds, :second)
  end

  # Закрытие входа взводится **стенными часами**, а не флагом уровня:
  # часы уровня стоят на перерыве, и по ним окно закрывалось бы позже
  # объявленного игроку `late_reg_until`. Тем же значением проверяет
  # вход и `Tournaments.check_slot/5` — два разных правила разошлись бы
  # на первом же перерыве.
  #
  # Без такого таймера фонд оставался бы нулевым весь турнир: единственным
  # местом фиксации был расчёт в самом конце, а витрина читает `prize_pool`
  # именно отсюда (`LobbyEntry.prize_pool/1`).
  defp arm_late_reg(%State{late_reg_until: nil} = state), do: state

  defp arm_late_reg(state) do
    left = max(DateTime.diff(state.late_reg_until, state.wall.(), :millisecond), 0)

    %{state | late_reg_timer: schedule(:late_reg_over, left)}
  end

  # Идемпотентно: фонд фиксируется один раз, и повторный тик таймера
  # (ручной прогон в тестах, гонка с расчётом) второй раз его не двигает.
  defp close_late_reg(%State{status: status} = state)
       when status in [:late_reg_closed, :finished],
       do: state

  defp close_late_reg(state) do
    with {:ok, tournament} <- Tournaments.get_tournament(state.tournament_id),
         {:ok, tournament} <- Tournaments.close_late_reg(tournament) do
      broadcast(state, "late_reg_closed", %{prize_pool: tournament.prize_pool})

      # Финальный стол — стадия более поздняя, и понижать её нельзя:
      # `Tournaments.close_late_reg/1` держит то же правило в БД.
      status = if state.status == :finishing, do: :finishing, else: :late_reg_closed

      %{state | status: status, late_reg_timer: nil}
    else
      {:error, reason} ->
        Logger.error(
          "турнир #{state.tournament_id}: не закрылась поздняя регистрация — #{inspect(reason)}"
        )

        state
    end
  end

  defp level_flags(state) do
    (state.snapshot["levels"] || [])
    |> Map.new(fn level -> {level["level"], level["rebuy_allowed"]} end)
  end

  # Рассадку мог уже сделать `prepare/1` за минуту до старта: тогда
  # столы стоят на паузе и остаётся их отпустить. Заново сажать нельзя —
  # игроки уже за столами.
  defp seat_prepared(%State{tables: tables} = state, _entries) when map_size(tables) > 0 do
    resume_tables(state)
    state
  end

  defp seat_prepared(state, entries) do
    state |> seat_all(entries) |> mark_seated_playing()
  end

  defp pause_tables(state) do
    Enum.each(state.tables, fn {_id, pid} -> send(pid, {:tournament_paused, true}) end)
    state
  end

  # Столов ровно столько, сколько нужно на явку, и заполняются они
  # равномерно: «полные плюс огрызок» дали бы перекос с первой раздачи.
  defp seat_all(state, entries) do
    table_size = table_size(state)
    count = Seating.tables_needed(length(entries), table_size)

    state = Enum.reduce(1..count//1, state, fn _index, acc -> open_table(acc) end)

    table_ids = Map.keys(state.tables)

    entries
    |> shuffle()
    |> Enum.with_index()
    |> Enum.reduce(state, fn {entry, index}, acc ->
      table_id = Enum.at(table_ids, rem(index, length(table_ids)))
      {:ok, acc} = seat_at(acc, entry, table_id)
      acc
    end)
  end

  # Стартовая рассадка случайна: кто с кем играет, решает не порядок
  # регистрации. Источник случайности криптографический — тот же, что
  # у колоды (§9 CLAUDE.md).
  defp shuffle(entries) do
    entries
    |> Enum.map(&{:crypto.strong_rand_bytes(16), &1})
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp open_table(state) do
    room_id = Ecto.UUID.generate()

    opts =
      Keyword.merge(state.room_opts,
        room_id: room_id,
        setting: table_setting(state),
        game_mode: BlockPoker.GameMode.Mtt,
        discipline: BlockPoker.Engine.Hand
      )

    case TableSupervisor.start_room(opts) do
      {:ok, pid} ->
        # Турнир слушает свои столы: конец раздачи — единственный момент,
        # когда он вправе что-то менять в рассадке.
        :ok = PubSub.subscribe(@pubsub, TableServer.topic(room_id))

        # И следит за тем, что они живы: комната `:temporary`, сама она
        # не поднимется, а её падение иначе унесло бы весь турнир — на
        # первом же вызове к мёртвому процессу.
        Process.monitor(pid)

        # Стол поднимается уже раздающим (`auto_start?`). Если турнир
        # сейчас стоит — перерыв или круг hand-for-hand, — новый стол
        # обязан встать вместе со всеми: иначе поздняя регистрация,
        # ре-энтри или пересадка после падения открыли бы стол, который
        # играет в перерыв.
        if state.break != nil or state.hand_for_hand != nil do
          send(pid, {:tournament_paused, true})
        end

        %{state | tables: Map.put(state.tables, room_id, pid)}

      {:error, reason} ->
        Logger.error("турнир #{state.tournament_id}: не поднялся стол — #{inspect(reason)}")
        state
    end
  end

  defp table_setting(state, opts \\ []) do
    setting = state.setting

    TableSetting.from_snapshot(
      state.snapshot,
      setting.id,
      state.tournament_id,
      Keyword.merge(
        [
          name: setting.name,
          action_timeout_ms: setting.action_timeout_ms,
          time_bank_ms: setting.time_bank_ms,
          time_bank_refill: setting.time_bank_refill,
          disconnect_grace_ms: setting.disconnect_grace_ms,
          button_draw_animation_ms: setting.button_draw_animation_ms,
          rebuy_prompt_ms: setting.rebuy_prompt_ms,
          felt_color: setting.felt_color,
          background_color: setting.background_color
        ],
        opts
      )
    )
  end

  # --- Посадка -------------------------------------------------------------

  defp seat_player(state, entry) do
    with {:ok, state} <- place_player(state, entry) do
      {:ok, _count} = Tournaments.mark_playing([entry.id])
      {:ok, state}
    end
  end

  # Стартовая рассадка идёт мимо `seat_player/2`, поэтому статус там
  # проставляется одним запросом на всех, а не по входу за раз: на явке
  # в три сотни это триста round-trip'ов на старте.
  defp mark_seated_playing(state) do
    {:ok, _count} = Tournaments.mark_playing(Map.keys(state.players))

    state
  end

  defp place_player(state, entry, stack \\ nil) do
    case least_filled_table(state) do
      nil ->
        state = open_table(state)

        case least_filled_table(state) do
          nil -> {:error, :no_table}
          table_id -> seat_at(state, entry, table_id, stack)
        end

      table_id ->
        seat_at(state, entry, table_id, stack)
    end
  end

  # Поздняя регистрация садится за наименее заполненный стол: это и
  # стандарт, и то, что не ломает баланс.
  defp least_filled_table(state) do
    state.tables
    |> Map.keys()
    |> Enum.reject(&(occupancy(state, &1) >= table_size(state)))
    |> Enum.min_by(&{occupancy(state, &1), &1}, fn -> nil end)
  end

  defp occupancy(state, table_id) do
    Enum.count(state.players, fn {_id, player} ->
      player.alive? and player.table_id == table_id
    end)
  end

  defp seat_at(state, entry, table_id, stack \\ nil) do
    pid = Map.fetch!(state.tables, table_id)

    # Стек приходит явно только при восстановлении: там он взят из
    # снимка, а не назначен заново. Новый вход считает `stack_for/2`.
    stack = stack || stack_for(state, entry)

    with {:ok, %{reservation_id: reservation, seat: seat}} <-
           TableServer.reserve_seat(pid, entry.user_id, :first_free, stack),
         {:ok, _seat} <- TableServer.confirm_seat(pid, reservation, stack, :wait_bb) do
      player = %Player{
        entry_id: entry.id,
        user_id: entry.user_id,
        stack: stack,
        table_id: table_id,
        seat: seat,
        bounty: entry.bounty
      }

      {:ok, %{state | players: Map.put(state.players, entry.id, player)}}
    end
  end

  # Стек зависит от того, чем игрок вошёл, и решает это турнир: стол
  # выдаёт ровно названное число.
  defp stack_for(state, entry) do
    if entry.entry_number > 1 do
      state.snapshot["rebuy_stack"] || state.snapshot["starting_stack"]
    else
      state.snapshot["starting_stack"]
    end
  end

  # --- Ре-энтри и аддон ----------------------------------------------------

  defp do_reenter(state, user_id) do
    # Окно ре-энтри снимается **до** оплаты: если игрок платит, вылета
    # не было, и место, зарезервированное за ним, освобождается.
    pending = Enum.find(state.pending_reentries, fn {_id, p} -> p.user_id == user_id end)

    with {:ok, entry} <- Tournaments.reenter(state.tournament_id, user_id) do
      state = drop_pending(state, pending)

      case seat_player(state, entry) do
        {:ok, state} ->
          broadcast(state, "reentry_taken", %{entry_id: entry.id, user_id: user_id})

          {:ok, entry, state}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp drop_pending(state, nil), do: state

  defp drop_pending(state, {entry_id, pending}) do
    cancel(pending.timer)

    %{state | pending_reentries: Map.delete(state.pending_reentries, entry_id)}
  end

  # Аддон берётся **на перерыве внутри разрешающего уровня** — на
  # пересечении двух правил, а не по одному флагу. Пять минут перерыва
  # и есть то время, за которое игрок решает.
  defp do_addon(state, user_id) do
    cond do
      # Финальный стол — это уже розыгрыш призов. Докупать фишки, когда
      # все оставшиеся в деньгах, нельзя ни на каком уровне: это меняло
      # бы расклад сил после того, как пузырь пройден.
      state.final_table != nil -> {:error, :addon_not_allowed}
      state.break == nil -> {:error, :addon_not_allowed}
      not level_allows_addon?(state) -> {:error, :addon_not_allowed}
      true -> charge_addon(state, user_id)
    end
  end

  defp level_allows_addon?(state) do
    (state.snapshot["levels"] || [])
    |> Enum.find(%{}, &(&1["level"] == state.level))
    |> Map.get("addon_allowed", false)
  end

  defp charge_addon(state, user_id) do
    with {:ok, entry} <- Tournaments.addon(state.tournament_id, user_id),
         {:ok, player} <- fetch_player(state, entry.id) do
      chips = state.snapshot["addon_stack"]

      # Фишки кладёт стол, но по указанию турнира: сам себе стек за
      # столом турнира никто не увеличивает.
      case Map.fetch(state.tables, player.table_id) do
        {:ok, pid} ->
          {:ok, stack} = TableServer.grant_chips(pid, user_id, chips)

          broadcast(state, "addon_taken", %{entry_id: entry.id, user_id: user_id, stack: stack})

          {:ok, stack, update_player(state, entry.id, &%{&1 | stack: stack})}

        :error ->
          {:error, :not_seated}
      end
    end
  end

  defp fetch_player(state, entry_id) do
    case Map.fetch(state.players, entry_id) do
      {:ok, player} -> {:ok, player}
      :error -> {:error, :not_registered}
    end
  end

  # --- Уровни --------------------------------------------------------------

  defp arm_level(state) do
    levels = TableSetting.levels(state.snapshot)

    if BlindSchedule.next?(levels, state.level) do
      left = BlindSchedule.duration_ms(levels, state.level) - state.level_elapsed_ms

      %{state | level_started_at: state.monotonic.(), level_timer: schedule(:level_up, left)}
    else
      # Последний уровень не кончается: турнир обязан заканчиваться
      # победителем, а не концом таблицы.
      %{state | level_started_at: nil, level_timer: nil}
    end
  end

  defp advance_level(state) do
    # Прошлый таймер снимается явно: по `:level_up` он уже сработал, а
    # вот ручной прогон (`fire/2`) оставил бы его висеть, и уровень
    # повысился бы второй раз сам собой.
    state = %{
      state
      | level: state.level + 1,
        level_elapsed_ms: 0,
        level_timer: cancel(state.level_timer)
    }

    state = arm_level(state)

    Enum.each(state.tables, fn {_id, pid} -> send(pid, {:tournament_level, state.level}) end)

    broadcast(state, "level_up", %{level: state.level, limits: limits(state)})

    state
  end

  # Пауза уровня: накопленное время сохраняется, таймер снимается.
  # Абсолютный дедлайн здесь не годится — он продолжал бы идти, пока
  # никто не играет, и уровень терял бы своё время.
  defp pause_level(%State{level_started_at: nil} = state), do: state

  defp pause_level(state) do
    elapsed = state.level_elapsed_ms + (state.monotonic.() - state.level_started_at)

    %{
      state
      | level_elapsed_ms: elapsed,
        level_started_at: nil,
        level_timer: cancel(state.level_timer)
    }
  end

  defp limits(state) do
    state.snapshot
    |> TableSetting.levels()
    |> BlindSchedule.at(state.level)
    |> Map.take([:small_blind, :big_blind, :ante])
  end

  # --- Перерывы ------------------------------------------------------------

  defp arm_break(state) do
    %{state | break_timer: schedule(:break_due, TournamentBreak.until_stop_ms(state.wall.()))}
  end

  # В `XX:55` турнир перестаёт раздавать **везде** и ждёт, пока
  # доиграются идущие раздачи. Стол, закончивший раньше, стоит: лишняя
  # раздача уехала бы в перерыв.
  defp begin_break(%State{break: break} = state) when break != nil, do: state

  defp begin_break(state) do
    waiting = MapSet.new(Map.keys(state.tables))

    state = %{state | break: %{waiting: waiting, ends_at: nil}, break_timer: nil}
    state = pause_level(state)

    Enum.each(state.tables, fn {_id, pid} -> send(pid, {:tournament_paused, true}) end)

    broadcast(state, "break_started", %{})

    if state.final_table == nil and level_allows_addon?(state) do
      broadcast(state, "addon_offer", %{
        deadline_ms: TournamentBreak.duration_ms(),
        cost: state.snapshot["addon_cost"],
        stack: state.snapshot["addon_stack"]
      })
    end

    # Столы, где раздача не идёт, готовы сразу: ждать от них нечего.
    # Столов может не быть вовсе (последний схлопнулся, единственный
    # упал) — тогда ждать некого, и перерыв обязан взвестись здесь же,
    # иначе `break_over` не запланирует уже никто.
    waiting
    |> Enum.reject(&busy?(state, &1))
    |> Enum.reduce(state, fn table_id, acc -> table_ready(acc, table_id) end)
    |> arm_break_end()
  end

  # Стол доиграл. Пять минут отсчитываются от **последнего** — перерыв не
  # сокращается на то, что где-то раздача затянулась.
  defp table_ready(%State{break: nil} = state, _table_id), do: state

  defp table_ready(state, table_id) do
    waiting = MapSet.delete(state.break.waiting, table_id)

    arm_break_end(%{state | break: %{state.break | waiting: waiting}})
  end

  # Ждать больше некого — пошли пять минут. Отдельной функцией, потому
  # что опустеть ожидание может тремя разными путями: стол доиграл, стол
  # закрылся при схлопывании и стол упал. Взвод конца перерыва обязан
  # случиться на каждом, иначе турнир стоит вечно.
  defp arm_break_end(%State{break: nil} = state), do: state

  defp arm_break_end(%State{break: %{ends_at: ends_at}} = state) when ends_at != nil, do: state

  defp arm_break_end(%State{break: break} = state) do
    if MapSet.size(break.waiting) == 0 do
      %{
        state
        | break: %{break | ends_at: TournamentBreak.ends_at(state.wall.())},
          break_timer: schedule(:break_over, TournamentBreak.duration_ms())
      }
    else
      state
    end
  end

  defp end_break(%State{break: nil} = state), do: state

  defp end_break(state) do
    broadcast(state, "break_ended", %{})

    state =
      %{state | break: nil, break_timer: nil}
      |> catch_up_seating()
      |> maybe_final_table()

    resume_tables(state)

    state
    |> arm_level()
    |> arm_break()
  end

  # Решения, отложенные перерывом.
  #
  # На перерыве `after_hand/2` уходит в ветку `table_ready/2`, то есть ни
  # балансировка, ни круг hand-for-hand за это время не пересчитываются.
  # Досчитать обязан конец перерыва, и это не косметика: `rebalance/1`
  # зовётся **только** из `after_hand/2`. Стол, оставшийся к концу
  # перерыва без пары, раздать не может и `hand_finished` больше не
  # пришлёт — а значит и пересадка, которая его спасла бы, не случится
  # никогда. Турнир встаёт навсегда.
  #
  # Порядок жёсткий: пересаживаем **до** снятия паузы. Поднятый стол
  # сразу начинает раздачу, а из-под идущей раздачи игрока не двигают
  # (`busy?/2`), и балансировка снова отложилась бы.
  defp catch_up_seating(state) do
    if bubble?(state) and split_field?(state) do
      # Баббл: пересадки нет по правилу, но круг начинается заново — все
      # столы выходят с перерыва одновременно.
      restart_hand_for_hand(state)
    else
      state |> rebalance() |> stop_hand_for_hand()
    end
  end

  defp restart_hand_for_hand(state) do
    state = start_hand_for_hand(state)

    %{state | hand_for_hand: %{waiting: dealing_tables(state)}}
  end

  # --- Конец раздачи -------------------------------------------------------

  defp on_hand_finished(state, payload) do
    state = %{state | hands_played: state.hands_played + 1}

    state
    |> settle_bounties(payload)
    |> eliminate(payload)
    |> update_stacks(payload)
    |> after_hand(payload.room_id)
    |> maybe_final_table()
    |> maybe_finish()
    |> save_snapshot()
  end

  # Рассадка и стеки — единственное, что не выводится из остальных таблиц,
  # и потому единственное, что теряется при падении процесса турнира
  # (`Tournaments.SeatSnapshot`). Пишется синхронно и последним шагом:
  # снимок — источник восстановления, и отставать от раздачи, которую он
  # описывает, ему нельзя. Дороже это ровно один upsert маленькой строки
  # на раздачу — на порядок меньше того, что процесс уже делает здесь же
  # (`pay_bounty`, `bust`, `current_payouts`).
  defp save_snapshot(%State{status: :finished} = state), do: state

  defp save_snapshot(state) do
    seats =
      for {_id, player} <- state.players, player.alive? and player.table_id != nil do
        %{
          "table" => player.table_id,
          "seat" => player.seat,
          "entry_id" => player.entry_id,
          "stack" => player.stack
        }
      end

    case Tournaments.save_snapshot(state.tournament_id, %{
           level: state.level,
           hands_played: state.hands_played,
           seats: seats
         }) do
      {:ok, _snapshot} ->
        state

      {:error, reason} ->
        # Снимок — страховка, а не игровой цикл: его отказ не имеет права
        # ронять турнир. Тот же размен, что у истории раздач (§6 задачи 6).
        Logger.error("турнир #{state.tournament_id}: снимок не записан — #{inspect(reason)}")

        state
    end
  end

  # Что делать со столом, доигравшим раздачу. Три взаимоисключающих
  # состояния турнира, и порядок проверок — это порядок приоритетов:
  # перерыв важнее баббла, баббл важнее балансировки.
  defp after_hand(state, table_id) do
    cond do
      state.break -> table_ready(state, table_id)
      bubble?(state) and split_field?(state) -> hand_for_hand(state, table_id)
      true -> state |> stop_hand_for_hand() |> rebalance(table_id)
    end
  end

  # --- Hand-for-hand -------------------------------------------------------

  # Баббл — момент, когда до призов остаётся ровно один вылет.
  #
  # Считается по сетке: сколько мест оплачивается при нынешней явке,
  # столько плюс один и есть баббл. Число это доменное, и берётся оно из
  # ядра (`Engine.TournamentPayout`), а не выводится здесь.
  defp bubble?(%State{status: :finished}), do: false

  defp bubble?(state) do
    alive_count(state) == paid_places(state) + 1
  end

  # Синхронный круг нужен, только пока раздают **несколько** столов.
  #
  # Hand-for-hand защищает от информационного преимущества: за медленным
  # столом игрок иначе узнал бы, что где-то уже вылетели, и доиграл бы
  # свою раздачу, зная, что деньги у него в кармане. Когда стол один,
  # узнавать не у кого и синхронизировать нечего — а пауза после каждой
  # раздачи есть. На малой явке (тот же 2-Max втроём) баббл наступает
  # с первой раздачи, и без этой оговорки турнир весь свой путь до
  # финала шёл бы в режиме hand-for-hand.
  defp split_field?(state), do: MapSet.size(dealing_tables(state)) > 1

  defp paid_places(state) do
    entries = map_size(state.players)
    people = state.players |> MapSet.new(fn {_id, player} -> player.user_id end) |> MapSet.size()

    TournamentPayout.paid_places(payout_rows(state), entries, people)
  end

  # Сетка выплат берётся из снапшота инстанса, а не из шаблона: снапшот
  # для того и снят, чтобы правка сетки посреди турнира не сдвинула
  # баббл под ногами у играющих. Разбор снапшота — в контексте, чтобы
  # призовая граница здесь и сумма вылетевшему (`Tournaments.current_payouts/1`)
  # читали одну и ту же сетку одним и тем же кодом.
  defp payout_rows(state), do: Tournaments.snapshot_payout_grid(state.snapshot)

  # На баббле столы играют **синхронно**: доигравший стоит и ждёт
  # остальных, и новый круг начинается у всех сразу.
  #
  # Без этого игрок за медленным столом получает информационное
  # преимущество: он видит, что где-то уже кто-то вылетел, и знает, что
  # деньги достанутся ему даже при проигрыше. Это правило честности,
  # а не опция, — флага в настройках у него нет.
  #
  # Балансировка на баббле не идёт: пересадка меняет позицию игрока
  # относительно блайндов, а это ровно то, от чего hand-for-hand
  # защищает.
  defp hand_for_hand(state, table_id) do
    state = start_hand_for_hand(state)

    pause_table(state, table_id)

    hand_for_hand_ready(state, table_id)
  end

  # Стол отыграл свой круг. Как и у перерыва, опустеть ожидание может не
  # только «доиграл»: стол мог закрыться при схлопывании или упасть.
  # Поэтому шаг вынесен и зовётся из всех трёх мест.
  defp hand_for_hand_ready(%State{hand_for_hand: nil} = state, _table_id), do: state

  defp hand_for_hand_ready(state, table_id) do
    waiting = MapSet.delete(state.hand_for_hand.waiting, table_id)

    if MapSet.size(waiting) == 0 do
      # Круг закончили все — начинаем следующий одновременно.
      resume_tables(state)

      %{state | hand_for_hand: %{waiting: dealing_tables(state)}}
    else
      %{state | hand_for_hand: %{waiting: waiting}}
    end
  end

  # Стол выбыл из турнира — закрылся при схлопывании или упал. Ждать от
  # него нечего: `hand_summary` он больше не пришлёт никогда, и
  # оставленный в ожидании он останавливает турнир навсегда — ни перерыв
  # не кончится, ни круг hand-for-hand не начнётся, а `rebalance/1`,
  # который мог бы спасти, зовётся только из `after_hand/2`.
  defp forget_table(state, table_id) do
    state
    |> table_ready(table_id)
    |> hand_for_hand_ready(table_id)
  end

  defp start_hand_for_hand(%State{hand_for_hand: nil} = state) do
    broadcast(state, "hand_for_hand", %{active: true, places: paid_places(state)})

    %{state | hand_for_hand: %{waiting: dealing_tables(state)}}
  end

  defp start_hand_for_hand(state), do: state

  # Баббл лопнул: кто-то вылетел, и оставшиеся уже в деньгах. Столы
  # расходятся по своим часам.
  defp stop_hand_for_hand(%State{hand_for_hand: nil} = state), do: state

  defp stop_hand_for_hand(state) do
    resume_tables(state)
    broadcast(state, "hand_for_hand", %{active: false})

    %{state | hand_for_hand: nil}
  end

  # Столы, которые в этом круге раздают.
  #
  # Стол, за которым меньше двух игроков, карт не сдаст и `hand_summary`
  # не пришлёт. Включённый в ожидание hand-for-hand, он остановил бы
  # турнир навсегда: остальные столы доиграли, встали на паузу и ждут
  # круга от того, кто раздать не может. На 2-Max с нечётной явкой это
  # случается с первой же раздачи — один игрок всегда сидит один.
  defp dealing_tables(state) do
    state.tables
    |> Map.keys()
    |> Enum.filter(&(occupancy(state, &1) >= 2))
    |> MapSet.new()
  end

  defp pause_table(state, table_id) do
    case Map.fetch(state.tables, table_id) do
      {:ok, pid} -> send(pid, {:tournament_paused, true})
      :error -> :ok
    end
  end

  defp resume_tables(state) do
    Enum.each(state.tables, fn {_id, pid} -> send(pid, {:tournament_paused, false}) end)
  end

  # Головы считаются до вылетов: цена головы принадлежит входу, и после
  # вылета её уже не спросить.
  defp settle_bounties(state, %{busted: []}), do: state

  defp settle_bounties(state, payload) do
    if bounty_part(state) == 0, do: state, else: do_settle_bounties(state, payload)
  end

  defp do_settle_bounties(state, payload) do
    victims =
      for entry <- payload.busted, player = player_at(state, payload.room_id, entry.seat) do
        %{
          entry_id: player.entry_id,
          seat: entry.seat,
          bounty: player.bounty,
          stack_before: entry.stack_before,
          killers: killers_of(state, payload, entry.seat)
        }
      end

    rules = %{
      progressive?: snapshot_value(state, "bounty_progressive", state.setting.bounty_progressive),
      split_ppm: snapshot_value(state, "bounty_split_ppm", state.setting.bounty_split_ppm)
    }

    table = %{button_seat: payload.button_seat || 1, table_size: table_size(state)}

    result = Bounty.settle(victims, rules, table)

    {:ok, tournament} = Tournaments.get_tournament(state.tournament_id)
    :ok = Tournaments.pay_bounty(tournament, result)

    Enum.each(result.payouts, fn payout ->
      broadcast(state, "bounty_won", %{
        killer_seat: payout.seat,
        victim_entry_id: payout.victim_entry_id,
        cash: payout.amount
      })
    end)

    apply_increments(state, result.increments)
  end

  # Убийца — победитель **того** банка, в котором у выбывшего кончились
  # фишки: не самого большого и не последнего, а того, где выбывший был
  # претендентом.
  defp killers_of(state, payload, seat) do
    payload.pots
    |> Enum.filter(&(seat in &1.eligible))
    |> Enum.flat_map(& &1.winners)
    |> Enum.uniq()
    |> Enum.flat_map(fn winner_seat ->
      case player_at(state, payload.room_id, winner_seat) do
        nil -> []
        player -> [%{entry_id: player.entry_id, seat: winner_seat}]
      end
    end)
  end

  defp apply_increments(state, increments) do
    Enum.reduce(increments, state, fn increment, acc ->
      update_player(acc, increment.entry_id, fn player ->
        %{player | bounty: player.bounty + increment.amount}
      end)
    end)
  end

  # Место присваивается по числу выживших **после** раздачи. Одновременный
  # вылет разводится по стеку на её начало.
  defp eliminate(state, %{busted: []}), do: state

  defp eliminate(state, payload) do
    victims =
      for entry <- payload.busted, player = player_at(state, payload.room_id, entry.seat) do
        %{entry_id: player.entry_id, seat: entry.seat, stack_before: entry.stack_before}
      end

    survivors = alive_count(state) - length(victims)

    table = %{button_seat: payload.button_seat || 1, table_size: table_size(state)}

    placements = Elimination.assign(victims, survivors, table)

    Enum.reduce(placements, state, fn placement, acc ->
      acc
      |> release_seat(placement.entry_id)
      |> update_player(placement.entry_id, &%{&1 | alive?: false, stack: 0, table_id: nil})
      |> resolve_bust(placement)
    end)
  end

  # Место вылетевшего освобождается сразу: оно нужно поздней
  # регистрации, ре-энтри и пересадкам, и держать его не за кем —
  # фишек у игрока нет. Сам стол этого не делает: снимать игрока
  # в турнире может только турнир (см. `GameMode.Mtt`).
  defp release_seat(state, entry_id) do
    with %{table_id: table_id} = player when table_id != nil <- Map.get(state.players, entry_id),
         {:ok, pid} <- Map.fetch(state.tables, table_id) do
      TableServer.pull_seat(pid, player.user_id)
    end

    state
  end

  # Вылет окончателен не всегда. Пока уровень разрешает вход и лимит
  # игрока не исчерпан, это **предложение войти заново**: место
  # резервируется, но не присваивается, и в результатах игрока ещё нет.
  #
  # Отказался или истёк таймер — место присвоено. Вошёл заново —
  # предыдущие места не сдвигаются, потому что у игрока просто нет вылета.
  defp resolve_bust(state, placement) do
    if reentry_open?(state, placement.entry_id) do
      offer_reentry(state, placement)
    else
      finalize_bust(state, placement.entry_id, placement)
    end
  end

  defp finalize_bust(state, entry_id, placement) do
    %{place: place} = placement
    shared = Map.get(placement, :shared_places) || [place]
    {:ok, entry} = Tournaments.bust(entry_id, place, if(shared == [place], do: nil, else: shared))
    prize = prize_for(state, placement)
    bounty_paid = bounty_earned_by(state, entry)

    # История пишется **в момент вылета каждого**, а не батчем в конце.
    # Турнир идёт часами, процесс может упасть или быть перезапущен
    # деплоем, и батч в конце — единственная точка, потеря которой стирает
    # результаты всех участников сразу. Дорога та же, что у раздач: `cast`
    # в Writer, потому что вылет — это ещё и пересадка, и проверка конца
    # уровня, и они не имеют права стоять в очереди за коннектом.
    History.persist_tournament_result_async(
      history_snapshot(state, entry, %{
        outcome: :busted,
        place: place,
        prize: prize,
        bounty_paid: bounty_paid,
        itm: prize > 0,
        finished_at: entry.busted_at || DateTime.utc_now()
      })
    )

    broadcast(state, "player_busted", %{
      entry_id: entry_id,
      place: place,
      # Итоговый `entry.prize` в БД появляется только при расчёте всего
      # турнира (`SettleTournament`), а вылетевший видит экран сразу.
      # Поэтому здесь — та же сетка «при текущей явке», что и в карточке
      # турнира (§3 задачи 30): не кэшируется, для мест вне призов — 0.
      prize: prize,
      bounty_earned: bounty_paid
    })

    state
    |> cancel_reentry_timer(entry_id)
    |> Map.update!(:results, &[result_row(entry_id, placement) | &1])
  end

  # Строка результата. `shared_places` едет с ней до самого расчёта:
  # именно по нему `Tournaments.settle/2` узнаёт, что два места слиты
  # в одно и их призы надо сложить и поделить (`Engine.Elimination`).
  defp result_row(entry_id, %{place: place} = placement) do
    %{
      entry_id: entry_id,
      place: place,
      shared_places: Map.get(placement, :shared_places) || [place]
    }
  end

  # Снимок входа для истории. Снимок, а не ссылка на `tournament_entries`:
  # та таблица принадлежит контексту `Tournaments`, будет меняться вместе
  # с механикой, и делать её вечным архивом значило бы запретить её
  # когда-либо чистить.
  defp history_snapshot(state, entry, attrs) do
    Map.merge(
      %{
        entry_id: entry.id,
        tournament_id: state.tournament_id,
        user_id: entry.user_id,
        title: state.setting.name,
        tournament_setting_id: state.setting.id,
        format: :mtt,
        # Масштаб взносов и призов: без него история покажет центы фишками.
        currency: state.setting.currency,
        bounty: state.setting.bounty_part > 0,
        entry_kind: if(entry.entry_number > 1, do: :reentry, else: :initial),
        # Нумерация входов с нуля: `entry_number` в рабочей таблице
        # считается с единицы, а средняя финишная позиция берётся по
        # максимальному индексу, и смещение обязано быть одним и тем же.
        entry_index: entry.entry_number - 1,
        buy_in: state.setting.buy_in,
        entry_fee: state.setting.entry_fee,
        addons_count: entry.addons_count,
        addons_cost: entry.addons_count * (state.setting.addon_cost || 0),
        # Цена собственной головы справочно: в ROI она не входит — это не
        # полученные деньги.
        bounty_final: entry.bounty,
        prize: 0,
        bounty_paid: 0,
        refund: 0,
        place: nil,
        # Без числа входов место не значит ничего: пятое из девяти и
        # пятое из девяноста — разные достижения.
        entrants: map_size(state.players),
        itm: false,
        hands_played: state.hands_played,
        started_at: entry.inserted_at,
        finished_at: DateTime.utc_now()
      },
      attrs
    )
  end

  defp record_winner(state, winner, payouts) do
    prize =
      case Enum.find(payouts, &(&1.place == 1)) do
        %{amount: amount} -> amount
        _none -> 0
      end

    case Tournaments.get_entry(winner.entry_id) do
      {:ok, entry} ->
        History.persist_tournament_result_async(
          history_snapshot(state, entry, %{
            outcome: :won,
            place: 1,
            prize: prize,
            bounty_paid: bounty_earned_by(state, entry),
            itm: prize > 0
          })
        )

      _error ->
        :ok
    end
  end

  # Сумма за место на момент вылета — по текущей явке, не по итогу
  # турнира: тот подводится один раз в конце (`SettleTournament`), а
  # вылетевший не может его ждать. Место вне призовой зоны — `0`.
  defp prize_for(state, %{place: place} = placement) do
    shared = Map.get(placement, :shared_places) || [place]

    with {:ok, tournament} <- Tournaments.get_tournament(state.tournament_id),
         {:ok, payouts} <- Tournaments.current_payouts(tournament) do
      Tournaments.share_of_places(payouts, shared, place)
    else
      _ -> 0
    end
  end

  # Не цена собственной головы (`entry.bounty` — растёт при PKO, достаётся
  # тому, кто выбьет уже этого игрока) и не то, что причитается, — то, что
  # игрок уже получил, выбивая чужие головы в этом турнире. Отдельного
  # счётчика для этого нет: сумма берётся из его же кошелька по записям
  # `tournament_bounty` с меткой турнира.
  defp bounty_earned_by(state, entry) do
    if bounty_part(state) == 0 do
      0
    else
      Tournaments.bounty_earned(entry.user_id, state.setting.currency, state.tournament_id)
    end
  end

  defp offer_reentry(state, placement) do
    # Фишек у входа больше нет, и место за столом он не занимает — вылет
    # записывается сразу. Не записывается только **место**: пока окно
    # открыто, вылет не окончателен, и место остаётся зарезервированным
    # в процессе. Без этой записи вход считался бы живым, и ре-энтри
    # тот же человек взять не смог бы.
    {:ok, _entry} = Tournaments.bust(placement.entry_id, nil)

    timer = schedule({:reentry_expired, placement.entry_id}, state.setting.rebuy_prompt_ms)

    player = Map.fetch!(state.players, placement.entry_id)

    broadcast(state, "reentry_offer", %{
      entry_id: placement.entry_id,
      user_id: player.user_id,
      deadline_ms: state.setting.rebuy_prompt_ms,
      cost: state.snapshot["rebuy_cost"],
      stack: state.snapshot["rebuy_stack"],
      left: reentries_left(state, player.user_id)
    })

    %{
      state
      | pending_reentries:
          Map.put(state.pending_reentries, placement.entry_id, %{
            placement: placement,
            user_id: player.user_id,
            timer: timer
          })
    }
  end

  # Вход открыт, пока не закрылась поздняя регистрация. Проверяем по
  # `late_reg_until`, а не по флагу текущего уровня: у уровня часы стоят
  # на перерыве (`TournamentBreak`), и после перерыва он ещё разрешал бы
  # вход, когда по стенным часам окно уже закрыто, — игрок получил бы
  # предложение, которое на оплате тут же отклонит `Tournaments.reenter/2`,
  # а турнир до этого отказа не считался бы закончившимся.
  defp reentry_open?(state, entry_id) do
    player = Map.get(state.players, entry_id)

    player != nil and state.snapshot["rebuy_allowed"] == true and
      late_reg_open?(state) and reentries_left(state, player.user_id) > 0
  end

  defp late_reg_open?(%State{late_reg_until: nil}), do: false

  defp late_reg_open?(%State{late_reg_until: until} = state) do
    DateTime.compare(state.wall.(), until) == :lt
  end

  # Сколько повторных входов осталось **этому человеку**. `nil` в
  # шаблоне означает «без ограничения».
  defp reentries_left(state, user_id) do
    case state.snapshot["max_rebuys"] do
      nil ->
        :infinity

      max ->
        used =
          Enum.count(state.players, fn {_id, player} ->
            player.user_id == user_id
          end) - 1

        max(max - used, 0)
    end
  end

  defp cancel_reentry_timer(state, entry_id) do
    case Map.pop(state.pending_reentries, entry_id) do
      {nil, _rest} ->
        state

      {pending, rest} ->
        cancel(pending.timer)
        %{state | pending_reentries: rest}
    end
  end

  defp update_stacks(state, payload) do
    Enum.reduce(payload.stacks, state, fn {seat, stack}, acc ->
      case player_at(acc, payload.room_id, seat) do
        nil -> acc
        player -> update_player(acc, player.entry_id, &%{&1 | stack: stack})
      end
    end)
  end

  # --- Балансировка --------------------------------------------------------

  defp rebalance(state, _table_id), do: rebalance(state)

  defp rebalance(%State{tables: tables} = state) when map_size(tables) < 2, do: state

  defp rebalance(state) do
    plan = state |> seating_view() |> Seating.plan(table_size(state))

    state
    |> apply_moves(plan.moves)
    |> close_tables(plan.close)
  end

  defp seating_view(state) do
    Enum.map(state.tables, fn {table_id, _pid} ->
      seats =
        Map.new(1..table_size(state), fn number ->
          {number, player_at(state, table_id, number)}
        end)

      %{
        id: table_id,
        seats: Map.new(seats, fn {number, player} -> {number, player && player.entry_id} end),
        big_blind_seat: nil,
        # Стол, где идёт раздача, не трогаем: игрока пересаживают только
        # между раздачами, и карт у него в этот момент нет по построению.
        busy?: busy?(state, table_id)
      }
    end)
  end

  defp close_table(state, table_id, pid, tables) do
    if empty?(pid) do
      PubSub.unsubscribe(@pubsub, TableServer.topic(table_id))
      TableSupervisor.stop_room(pid)
      %{state | tables: tables}
    else
      Logger.error("турнир #{state.tournament_id}: стол #{table_id} не закрыт — за ним ещё сидят")

      state
    end
  end

  defp empty?(pid), do: pid |> TableServer.state() |> RoomState.players() == []

  defp busy?(state, table_id) do
    case Map.fetch(state.tables, table_id) do
      {:ok, pid} -> TableServer.state(pid).hand != nil
      :error -> false
    end
  end

  defp apply_moves(state, moves) do
    Enum.reduce(moves, state, fn move, acc ->
      case Map.fetch(acc.players, move.player) do
        {:ok, player} -> move_player(acc, player, move)
        :error -> acc
      end
    end)
  end

  defp move_player(state, player, move) do
    with {:ok, from} <- Map.fetch(state.tables, move.from),
         {:ok, to} <- Map.fetch(state.tables, move.to),
         # Стек берётся у покидаемого стола, а не из своей копии: она
         # обновляется по концу раздачи, а пересадка идёт следом, и
         # разойтись они не должны — фишки не могут потеряться между
         # двумя комнатами.
         {:ok, stack} <- TableServer.pull_seat(from, player.user_id) do
      case seat_moved(state, to, player, move, stack) do
        {:ok, state} -> state
        {:error, reason} -> return_player(state, from, player, stack, reason)
      end
    else
      _other -> state
    end
  end

  defp seat_moved(state, to, player, move, stack) do
    with {:ok, %{reservation_id: reservation, seat: seat}} <-
           TableServer.reserve_seat(to, player.user_id, move.seat, stack),
         {:ok, _seat} <- TableServer.confirm_seat(to, reservation, stack, :wait_bb) do
      broadcast(state, "table_changed", %{
        entry_id: player.entry_id,
        table_id: move.to,
        seat: seat
      })

      {:ok,
       update_player(
         state,
         player.entry_id,
         &%{&1 | table_id: move.to, seat: seat, stack: stack}
       )}
    end
  end

  # Между «сняли со стола» и «посадили за другой» фишки не лежат нигде:
  # они уже вышли из покидаемой комнаты и ещё не вошли в принимающую.
  # Если посадить не вышло — а это значит, что представление турнира о
  # свободных местах разошлось с самой комнатой, — игрок возвращается
  # туда, откуда его сняли. Молча оставить его без стола нельзя: он
  # числился бы живым со стеком, которого нет ни за одним столом.
  defp return_player(state, from, player, stack, reason) do
    Logger.error(
      "турнир #{state.tournament_id}: пересадка входа #{player.entry_id} не удалась " <>
        "(#{inspect(reason)}), возвращаем за прежний стол"
    )

    with {:ok, %{reservation_id: reservation, seat: seat}} <-
           TableServer.reserve_seat(from, player.user_id, :first_free, stack),
         {:ok, _seat} <- TableServer.confirm_seat(from, reservation, stack, :wait_bb) do
      update_player(state, player.entry_id, &%{&1 | seat: seat, stack: stack})
    else
      error ->
        Logger.error(
          "турнир #{state.tournament_id}: вход #{player.entry_id} остался без стола " <>
            "со стеком #{stack} — #{inspect(error)}"
        )

        state
    end
  end

  # Рассылка в канал стола, а не турнира: игрок за столом на топик
  # турнира не подписан (это топик окна лобби), только на топик своей
  # комнаты — тот же, что слушает `Socket.TableChannel`.
  defp notify_tables(state, event, payload) do
    Enum.each(state.tables, fn {table_id, _pid} ->
      PubSub.broadcast(
        @pubsub,
        TableServer.topic(table_id),
        {:table_event, event, Map.put(payload, :room_id, table_id)}
      )
    end)
  end

  # Стол закрывается только **пустым**. План закрытия составлен до
  # пересадок и исходит из того, что все они прошли; не прошедшая
  # пересадка оставляет игрока за столом, который план велит закрыть, —
  # и вместе со столом умерли бы его фишки.
  defp close_tables(state, table_ids) do
    Enum.reduce(table_ids, state, fn table_id, acc ->
      case Map.pop(acc.tables, table_id) do
        {nil, _tables} ->
          acc

        {pid, tables} ->
          acc |> close_table(table_id, pid, tables) |> forget_closed(table_id)
      end
    end)
  end

  # Ожидания перерыва и круга чистятся только у **действительно**
  # закрытого стола: `close_table/4` отказывается гасить стол, за которым
  # ещё сидят, и такой стол продолжает раздавать и присылать `hand_summary`.
  defp forget_closed(state, table_id) do
    if Map.has_key?(state.tables, table_id), do: state, else: forget_table(state, table_id)
  end

  # --- Падение стола -------------------------------------------------------

  # Игроки упавшего стола пересаживаются за новый со стеками **на конец
  # последней раздачи**: именно они лежат в `players` и обновляются
  # после каждой раздачи. Незавершённая раздача при этом аннулируется, и
  # вложенное в неё возвращается игрокам — то же правило, что у кэш-стола
  # (§8 CLAUDE.md).
  defp recover_table(state, table_id, reason) do
    Logger.error(
      "турнир #{state.tournament_id}: упал стол #{table_id} (#{inspect(reason)}) — поднимаем заново"
    )

    PubSub.unsubscribe(@pubsub, TableServer.topic(table_id))

    orphans =
      state.players
      |> Map.values()
      |> Enum.filter(&(&1.alive? and &1.table_id == table_id))

    state = %{state | tables: Map.delete(state.tables, table_id)}
    state = if state.final_table == table_id, do: %{state | final_table: nil}, else: state

    # Мёртвый стол вычёркивается из ожиданий **до** пересадки: иначе
    # перерыв или круг hand-for-hand ждали бы от него раздачу, которой
    # уже никогда не будет.
    state = forget_table(state, table_id)

    state = Enum.reduce(orphans, state, &reseat_orphan(&2, &1))

    broadcast(state, "table_recovered", %{table_id: table_id})

    state
  end

  defp reseat_orphan(state, player) do
    state = if least_filled_table(state) == nil, do: open_table(state), else: state

    with table_id when table_id != nil <- least_filled_table(state),
         {:ok, pid} <- Map.fetch(state.tables, table_id),
         {:ok, %{reservation_id: reservation, seat: seat}} <-
           TableServer.reserve_seat(pid, player.user_id, :first_free, player.stack),
         {:ok, _seat} <- TableServer.confirm_seat(pid, reservation, player.stack, :wait_bb) do
      broadcast(state, "table_changed", %{
        entry_id: player.entry_id,
        table_id: table_id,
        seat: seat
      })

      update_player(state, player.entry_id, &%{&1 | table_id: table_id, seat: seat})
    else
      error ->
        Logger.error(
          "турнир #{state.tournament_id}: вход #{player.entry_id} не сел после падения стола " <>
            "— #{inspect(error)}"
        )

        state
    end
  end

  # --- Финал ---------------------------------------------------------------

  defp maybe_final_table(%State{final_table: table} = state) when table != nil, do: state

  defp maybe_final_table(state) do
    if map_size(state.tables) == 1 and alive_count(state) <= table_size(state) do
      [{table_id, pid}] = Map.to_list(state.tables)

      # Финалка — событие турнира, а не настройка комнаты: стол берёт
      # вторую пару цветов, потому что турнир сказал ему, что он финальный.
      send(
        pid,
        {:tournament_final_table,
         table_setting(state,
           final?: true,
           felt_color: state.setting.final_felt_color,
           background_color: state.setting.final_background_color
         )}
      )

      {:ok, tournament} = Tournaments.get_tournament(state.tournament_id)
      {:ok, _tournament} = Tournaments.to_final_table(tournament)

      broadcast(state, "final_table", %{table_id: table_id})

      %{state | final_table: table_id, status: :finishing}
    else
      state
    end
  end

  # Турнир не может закончиться, пока кому-то предложено войти заново:
  # вылет ещё не окончателен, и «единственный живой» — не победитель,
  # а тот, кто ждёт ответа соперника.
  defp maybe_finish(%State{pending_reentries: pending} = state) when map_size(pending) > 0 do
    state
  end

  defp maybe_finish(%State{status: :finished} = state), do: state

  defp maybe_finish(state) do
    case alive_players(state) do
      [winner] ->
        results = [%{entry_id: winner.entry_id, place: 1, shared_places: [1]} | state.results]

        {:ok, tournament} = Tournaments.get_tournament(state.tournament_id)
        {:ok, tournament} = ensure_pool_fixed(tournament)
        {:ok, payouts} = Tournaments.settle(tournament, results)

        # Клиенту едет то, что вход **получил**, а не то, сколько стоит
        # его место: при слитых местах одновременного вылета это разные
        # числа, и считает их ядро (`Tournaments.award_amounts/2`).
        payload = %{results: with_prizes(results, payouts), payouts: payouts}

        # Победитель не вылетает, и `finalize_bust` для него не
        # вызывается — строку истории ему пишет завершение турнира.
        # Дозапись идемпотентна по `entry_id`: у вылетевших строки уже
        # есть, и вторых не появится.
        record_winner(state, winner, payouts)

        broadcast(state, "tournament_finished", payload)

        # Победитель сидит в канале своего стола, а не турнира — сам он
        # на `Tournaments.topic/1` не подписан. Без этого сообщения его
        # канал молча замолчит: `TableChannel` процесс стола не
        # мониторит, и `close_finished_tables` ниже для него неотличим
        # от обрыва связи.
        notify_tables(state, "tournament_finished", payload)
        schedule(:close_finished_tables, @tables_close_ms)

        %{state | status: :finished, results: results}

      _more ->
        state
    end
  end

  defp with_prizes(results, payouts) do
    won = Map.new(Tournaments.award_amounts(results, payouts), &{&1.entry_id, &1.amount})

    Enum.map(results, fn result ->
      %{entry_id: result.entry_id, place: result.place, prize: Map.get(won, result.entry_id, 0)}
    end)
  end

  # Фонд фиксируется на закрытии поздней регистрации. Если турнир
  # закончился раньше, чем оно случилось, фиксируем здесь: выплачивать
  # из незафиксированного фонда нечем.
  defp ensure_pool_fixed(%Tournament{status: :late_reg_closed} = tournament),
    do: {:ok, tournament}

  defp ensure_pool_fixed(%Tournament{prize_pool: pool} = tournament) when pool > 0,
    do: {:ok, tournament}

  defp ensure_pool_fixed(tournament), do: Tournaments.close_late_reg(tournament)

  # --- Служебное -----------------------------------------------------------

  # Размер стола и правила голов читаются из **снапшота инстанса**, а не
  # из живого шаблона: снапшот для того и снят, чтобы правка шаблона не
  # меняла турнир под ногами у играющих (§6 CLAUDE.md). Через `state.setting`
  # они приходили бы заново при каждом перезапуске процесса — то есть
  # ровно в момент, когда турнир и так восстанавливается.
  #
  # Шаблон остаётся запасным значением: снапшот инстанса, снятый до
  # появления поля, его не содержит.
  defp table_size(state), do: snapshot_value(state, "table_size", state.setting.table_size)

  defp bounty_part(state), do: snapshot_value(state, "bounty_part", state.setting.bounty_part)

  defp snapshot_value(state, key, fallback) do
    case Map.get(state.snapshot, key) do
      nil -> fallback
      value -> value
    end
  end

  defp alive_players(state) do
    state.players |> Map.values() |> Enum.filter(& &1.alive?)
  end

  defp alive_count(state), do: length(alive_players(state))

  defp player_at(state, table_id, seat) do
    Enum.find_value(state.players, fn {_id, player} ->
      if player.alive? and player.table_id == table_id and player.seat == seat, do: player
    end)
  end

  # Неизвестный вход не заводится: `Map.update/4` подставил бы дефолт,
  # и в `players` появился бы `nil`, на котором упали бы `occupancy/2` и
  # `player_at/3`. Пропуск здесь честнее — обновлять нечего.
  defp update_player(state, entry_id, fun) do
    case Map.fetch(state.players, entry_id) do
      {:ok, player} -> %{state | players: Map.put(state.players, entry_id, fun.(player))}
      :error -> state
    end
  end

  defp schedule(message, ms) when is_integer(ms) and ms >= 0 do
    Process.send_after(self(), message, ms)
  end

  defp schedule(_message, _ms), do: nil

  defp cancel(nil), do: nil

  defp cancel(timer) do
    Process.cancel_timer(timer)
    nil
  end

  defp snapshot(state) do
    %{
      tournament_id: state.tournament_id,
      status: state.status,
      level: state.level,
      limits: limits(state),
      players_left: alive_count(state),
      entries: map_size(state.players),
      tables: map_size(state.tables),
      on_break: state.break != nil,
      hand_for_hand: state.hand_for_hand != nil,
      next_payout_place: paid_places(state),
      final_table: state.final_table,
      hands_played: state.hands_played
    }
  end

  defp broadcast(state, event, payload) do
    PubSub.broadcast(
      @pubsub,
      Tournaments.topic(state.tournament_id),
      {:tournament_event, event, Map.put(payload, :tournament_id, state.tournament_id)}
    )
  end
end
