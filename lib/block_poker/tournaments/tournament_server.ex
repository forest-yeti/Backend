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

  alias BlockPoker.Engine.{Bounty, BlindSchedule, Elimination, Seating, TournamentBreak}
  alias BlockPoker.Tables.{TableRegistry, TableServer, TableSupervisor}
  alias BlockPoker.Tournaments
  alias BlockPoker.Tournaments.{TableSetting, Tournament}
  alias Phoenix.PubSub

  @pubsub BlockPoker.PubSub

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
      # Перерыв: `nil` — играем; `%{stop_at, waiting: MapSet, ends_at}`.
      break: nil,
      break_timer: nil,
      status: :registering,
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

  @doc "Сажает вход за стол: поздняя регистрация и ре-энтри приходят сюда."
  @spec seat_entry(Ecto.UUID.t() | pid(), map()) :: :ok | {:error, atom()}
  def seat_entry(tournament, entry), do: GenServer.call(server(tournament), {:seat, entry})

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

      {:ok, state}
    end
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, snapshot(state), state}

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

  def handle_call({:seat, entry}, _from, state) do
    case seat_player(state, entry) do
      {:ok, state} -> {:reply, :ok, state}
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

  @impl true
  def handle_info(:level_up, state), do: {:noreply, advance_level(state)}

  def handle_info(:break_due, state), do: {:noreply, begin_break(state)}

  def handle_info(:break_over, state), do: {:noreply, end_break(state)}

  # Раздача закончилась: это единственный момент, когда турнир вправе
  # что-то менять за столом — между раздачами. Здесь и вылеты, и головы,
  # и балансировка, и вход в перерыв.
  def handle_info({:table_event, "hand_summary", payload}, state) do
    {:noreply, on_hand_finished(state, payload)}
  end

  def handle_info({:table_event, _event, _payload}, state), do: {:noreply, state}

  def handle_info({:tournament_updated, _id}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  # --- Старт ---------------------------------------------------------------

  defp do_start(state, %Tournament{} = tournament) do
    entries = Tournaments.list_seated(tournament.id)

    if length(entries) < state.setting.min_players do
      {:reply, {:error, :not_enough_players}, state}
    else
      {:ok, _tournament} = Tournaments.start(tournament, late_reg_until(state))

      state =
        %{state | status: :running}
        |> seat_all(entries)
        |> arm_level()
        |> arm_break()

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

  defp level_flags(state) do
    (state.snapshot["levels"] || [])
    |> Map.new(fn level -> {level["level"], level["rebuy_allowed"]} end)
  end

  # Столов ровно столько, сколько нужно на явку, и заполняются они
  # равномерно: «полные плюс огрызок» дали бы перекос с первой раздачи.
  defp seat_all(state, entries) do
    table_size = state.setting.table_size
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
    case least_filled_table(state) do
      nil ->
        state = open_table(state)

        case least_filled_table(state) do
          nil -> {:error, :no_table}
          table_id -> seat_at(state, entry, table_id)
        end

      table_id ->
        seat_at(state, entry, table_id)
    end
  end

  # Поздняя регистрация садится за наименее заполненный стол: это и
  # стандарт, и то, что не ломает баланс.
  defp least_filled_table(state) do
    state.tables
    |> Map.keys()
    |> Enum.reject(&(occupancy(state, &1) >= state.setting.table_size))
    |> Enum.min_by(&{occupancy(state, &1), &1}, fn -> nil end)
  end

  defp occupancy(state, table_id) do
    Enum.count(state.players, fn {_id, player} ->
      player.alive? and player.table_id == table_id
    end)
  end

  defp seat_at(state, entry, table_id) do
    pid = Map.fetch!(state.tables, table_id)
    stack = stack_for(state, entry)

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
    state = %{state | level: state.level + 1, level_elapsed_ms: 0}
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

    # Столы, где раздача не идёт, готовы сразу: ждать от них нечего.
    Enum.reduce(waiting, state, fn table_id, acc -> table_ready(acc, table_id) end)
  end

  # Стол доиграл. Пять минут отсчитываются от **последнего** — перерыв не
  # сокращается на то, что где-то раздача затянулась.
  defp table_ready(%State{break: nil} = state, _table_id), do: state

  defp table_ready(state, table_id) do
    waiting = MapSet.delete(state.break.waiting, table_id)
    break = %{state.break | waiting: waiting}

    if MapSet.size(waiting) == 0 and break.ends_at == nil do
      ends_at = TournamentBreak.ends_at(state.wall.())

      %{
        state
        | break: %{break | ends_at: ends_at},
          break_timer: schedule(:break_over, TournamentBreak.duration_ms())
      }
    else
      %{state | break: break}
    end
  end

  defp end_break(%State{break: nil} = state), do: state

  defp end_break(state) do
    Enum.each(state.tables, fn {_id, pid} -> send(pid, {:tournament_paused, false}) end)

    broadcast(state, "break_ended", %{})

    %{state | break: nil, break_timer: nil}
    |> arm_level()
    |> arm_break()
  end

  # --- Конец раздачи -------------------------------------------------------

  defp on_hand_finished(state, payload) do
    state = %{state | hands_played: state.hands_played + 1}

    state
    |> settle_bounties(payload)
    |> eliminate(payload)
    |> update_stacks(payload)
    |> then(fn state ->
      if state.break, do: table_ready(state, payload.room_id), else: rebalance(state)
    end)
    |> maybe_final_table()
    |> maybe_finish()
  end

  # Головы считаются до вылетов: цена головы принадлежит входу, и после
  # вылета её уже не спросить.
  defp settle_bounties(state, %{busted: []}), do: state

  defp settle_bounties(%State{setting: %{bounty_part: 0}} = state, _payload), do: state

  defp settle_bounties(state, payload) do
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
      progressive?: state.setting.bounty_progressive,
      split_ppm: state.setting.bounty_split_ppm
    }

    table = %{
      button_seat: payload.button_seat || 1,
      table_size: state.setting.table_size
    }

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

    table = %{button_seat: payload.button_seat || 1, table_size: state.setting.table_size}

    placements = Elimination.assign(victims, survivors, table)

    Enum.reduce(placements, state, fn placement, acc ->
      {:ok, _entry} = Tournaments.bust(placement.entry_id, placement.place)

      broadcast(acc, "player_busted", %{entry_id: placement.entry_id, place: placement.place})

      acc
      |> update_player(placement.entry_id, &%{&1 | alive?: false, stack: 0, table_id: nil})
      |> Map.update!(:results, &[%{entry_id: placement.entry_id, place: placement.place} | &1])
    end)
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

  defp rebalance(%State{tables: tables} = state) when map_size(tables) < 2, do: state

  defp rebalance(state) do
    plan = state |> seating_view() |> Seating.plan(state.setting.table_size)

    state
    |> apply_moves(plan.moves)
    |> close_tables(plan.close)
  end

  defp seating_view(state) do
    Enum.map(state.tables, fn {table_id, _pid} ->
      seats =
        Map.new(1..state.setting.table_size, fn number ->
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
      case TableServer.reserve_seat(to, player.user_id, move.seat, stack) do
        {:ok, %{reservation_id: reservation, seat: seat}} ->
          {:ok, _seat} = TableServer.confirm_seat(to, reservation, stack, :wait_bb)

          broadcast(state, "table_changed", %{
            entry_id: player.entry_id,
            table_id: move.to,
            seat: seat
          })

          update_player(
            state,
            player.entry_id,
            &%{&1 | table_id: move.to, seat: seat, stack: stack}
          )

        {:error, _reason} ->
          state
      end
    else
      _other -> state
    end
  end

  defp close_tables(state, table_ids) do
    Enum.reduce(table_ids, state, fn table_id, acc ->
      case Map.pop(acc.tables, table_id) do
        {nil, _tables} ->
          acc

        {pid, tables} ->
          PubSub.unsubscribe(@pubsub, TableServer.topic(table_id))
          TableSupervisor.stop_room(pid)
          %{acc | tables: tables}
      end
    end)
  end

  # --- Финал ---------------------------------------------------------------

  defp maybe_final_table(%State{final_table: table} = state) when table != nil, do: state

  defp maybe_final_table(state) do
    if map_size(state.tables) == 1 and alive_count(state) <= state.setting.table_size do
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

  defp maybe_finish(state) do
    case alive_players(state) do
      [winner] ->
        results = [%{entry_id: winner.entry_id, place: 1} | state.results]

        {:ok, tournament} = Tournaments.get_tournament(state.tournament_id)
        {:ok, tournament} = ensure_pool_fixed(tournament)
        {:ok, payouts} = Tournaments.settle(tournament, results)

        broadcast(state, "tournament_finished", %{results: results, payouts: payouts})

        state = close_tables(state, Map.keys(state.tables))

        %{state | status: :finished, results: results}

      _more ->
        state
    end
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

  defp alive_players(state) do
    state.players |> Map.values() |> Enum.filter(& &1.alive?)
  end

  defp alive_count(state), do: length(alive_players(state))

  defp player_at(state, table_id, seat) do
    Enum.find_value(state.players, fn {_id, player} ->
      if player.alive? and player.table_id == table_id and player.seat == seat, do: player
    end)
  end

  defp update_player(state, entry_id, fun) do
    %{state | players: Map.update(state.players, entry_id, nil, fun)}
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
