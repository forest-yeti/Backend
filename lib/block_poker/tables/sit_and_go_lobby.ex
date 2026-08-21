defmodule BlockPoker.Tables.SitAndGoLobby do
  @moduledoc """
  Пул турниров Sit & Go: единственный владелец списка идущих и набираемых
  столов.

  Инвариант тот же по форме, что и в кэше, но означает другое:

  > Для каждого включённого шаблона существует **ровно один** турнир,
  > открытый на регистрацию.

  Открытый — это не начатый и с местами. Как только пул собрался, турнир
  стартует и перестаёт быть открытым: под шаблон немедленно поднимается
  следующий, чтобы очередь никогда не упиралась в «мест нет».

  ## Почему отдельный процесс, а не общий с кэшем

  Комната кэша не заканчивается — она пустеет и ждёт новых игроков. Турнир
  заканчивается всегда, и его конец — событие, после которого стол обязан
  исчезнуть. Сводить два жизненных цикла в один процесс значило бы
  ветвиться по режиму в каждой ветке пула, а витрины у них и вовсе разные:
  кэш показывает блайнды и лимиты, турнир — взнос, стек и множители.

  Сам стол при этом тот же самый `TableServer`: различает их режим
  (`GameMode.Tournament`), а не отдельная реализация.
  """

  use GenServer

  require Logger

  alias BlockPoker.SitAndGo
  alias BlockPoker.SitAndGo.SitAndGoSetting
  alias BlockPoker.Tables.{TableRegistry, TableServer, TableSupervisor}
  alias Phoenix.PubSub

  @pubsub BlockPoker.PubSub
  @topic "sit_n_go_lobby_events"
  @default_reload_ms :timer.minutes(1)

  defmodule Room do
    @moduledoc false
    @enforce_keys [:room_id, :setting_id, :pid, :max_players]
    defstruct [
      :room_id,
      :setting_id,
      :pid,
      :max_players,
      seats_taken: 0,
      started?: false,
      draining?: false
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Топик, в который уходят обновления витрины турниров."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Перечитать шаблоны из БД и привести пул в соответствие."
  @spec reload(GenServer.server()) :: :ok
  def reload(server \\ __MODULE__), do: GenServer.call(server, :reload)

  @doc """
  Витрина: шаблоны с числом уже зарегистрированных.

  `game_types` сужает выборку по дисциплине; пустой список означает «все»
  — экран с ничем не отмеченным фильтром обязан показывать весь пул,
  а не пустоту.
  """
  @spec snapshot(GenServer.server(), [atom()]) :: [map()]
  def snapshot(server \\ __MODULE__, game_types \\ []) do
    GenServer.call(server, {:snapshot, game_types})
  end

  @doc "Турнир шаблона, открытый на регистрацию, — по инварианту он один."
  @spec open_room(GenServer.server(), Ecto.UUID.t()) ::
          {:ok, Ecto.UUID.t()} | {:error, :no_seats_available | :not_found}
  def open_room(server \\ __MODULE__, setting_id) do
    GenServer.call(server, {:open_room, setting_id})
  end

  @spec rooms(GenServer.server()) :: [Room.t()]
  def rooms(server \\ __MODULE__), do: GenServer.call(server, :rooms)

  @spec settings(GenServer.server()) :: [SitAndGoSetting.t()]
  def settings(server \\ __MODULE__), do: GenServer.call(server, :settings)

  @impl true
  def init(opts) do
    PubSub.subscribe(@pubsub, TableServer.rooms_topic())

    state = %{
      settings: %{},
      rooms: %{},
      reload_ms: Keyword.get(opts, :reload_ms, @default_reload_ms),
      room_opts: Keyword.get(opts, :room_opts, [])
    }

    {:ok, state, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    state = do_reload(state)
    schedule_reload(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    {:reply, :ok, do_reload(state)}
  end

  def handle_call({:snapshot, game_types}, _from, state) do
    {:reply, build_snapshot(state, game_types), state}
  end

  def handle_call(:settings, _from, state), do: {:reply, Map.values(state.settings), state}

  def handle_call(:rooms, _from, state), do: {:reply, Map.values(state.rooms), state}

  def handle_call({:open_room, setting_id}, _from, state) do
    case Map.fetch(state.settings, setting_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, setting} ->
        case pick_room(state, setting) do
          nil -> {:reply, {:error, :no_seats_available}, state}
          room -> {:reply, {:ok, room.room_id}, state}
        end
    end
  end

  @impl true
  def handle_info({:room_changed, summary}, state) do
    # Топик комнат один на все столы, включая кэшевые: чужие сводки
    # пропускаем, иначе пул считал бы своими комнаты другого режима.
    if Map.has_key?(state.rooms, summary.room_id) do
      state =
        state
        |> update_room(summary)
        |> enforce_invariant(summary.setting_id)

      broadcast_update(state, summary.setting_id)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Enum.find(state.rooms, fn {_id, room} -> room.pid == pid end) do
      nil ->
        {:noreply, state}

      {room_id, room} ->
        state = %{state | rooms: Map.delete(state.rooms, room_id)}
        state = enforce_invariant(state, room.setting_id)
        broadcast_update(state, room.setting_id)
        {:noreply, state}
    end
  end

  def handle_info(:reload, state) do
    state = do_reload(state)
    schedule_reload(state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # --- пул -----------------------------------------------------------------

  defp do_reload(state) do
    settings = Map.new(SitAndGo.list_settings(), &{&1.id, &1})
    state = %{state | settings: settings}
    state = Enum.reduce(Map.values(settings), state, &enforce_invariant(&2, &1.id))

    orphans =
      state.rooms
      |> Map.values()
      |> Enum.reject(&Map.has_key?(settings, &1.setting_id))

    Enum.reduce(orphans, state, &drain_room(&2, &1))
  end

  # Ядро конструкции: ровно один открытый на регистрацию турнир.
  defp enforce_invariant(state, setting_id) do
    case Map.fetch(state.settings, setting_id) do
      :error -> state
      {:ok, setting} -> do_enforce(state, setting)
    end
  end

  defp do_enforce(state, setting) do
    rooms = rooms_of(state, setting.id)
    open = Enum.filter(rooms, &open?/1)

    cond do
      open == [] and length(rooms) < setting.max_rooms ->
        start_room(state, setting)

      # Лишние пустые наборы схлопываются в один: иначе игроки размазываются
      # по нескольким недобранным турнирам и ни один не стартует.
      length(open) > 1 ->
        close_extra(state, open)

      true ->
        state
    end
  end

  defp close_extra(state, open) do
    keep = Enum.max_by(open, & &1.seats_taken)

    open
    |> Enum.reject(&(&1.room_id == keep.room_id))
    |> Enum.filter(&(&1.seats_taken == 0))
    |> Enum.reduce(state, &close_room(&2, &1))
  end

  defp start_room(state, setting) do
    room_id = Ecto.UUID.generate()

    opts =
      Keyword.merge(state.room_opts,
        room_id: room_id,
        setting: setting,
        game_mode: BlockPoker.GameMode.Tournament
      )

    case TableSupervisor.start_room(opts) do
      {:ok, pid} ->
        Process.monitor(pid)

        room = %Room{
          room_id: room_id,
          setting_id: setting.id,
          pid: pid,
          max_players: setting.max_players
        }

        %{state | rooms: Map.put(state.rooms, room_id, room)}

      {:error, reason} ->
        Logger.error("не удалось поднять турнир шаблона #{setting.id}: #{inspect(reason)}")
        state
    end
  end

  defp close_room(state, room) do
    case TableServer.close_if_idle(room.pid) do
      :ok ->
        TableSupervisor.stop_room(room.pid)
        %{state | rooms: Map.delete(state.rooms, room.room_id)}

      {:error, :busy} ->
        drain_room(state, room)
    end
  end

  defp drain_room(state, room) do
    if room.draining? do
      state
    else
      TableServer.drain(room.pid)
      put_room(state, %{room | draining?: true})
    end
  end

  defp update_room(state, summary) do
    case Map.fetch(state.rooms, summary.room_id) do
      :error ->
        state

      {:ok, room} ->
        room = %{
          room
          | seats_taken: summary.seats_taken,
            started?: summary.game_started?,
            draining?: summary.draining?
        }

        if room.draining? and room.seats_taken == 0 and
             TableServer.close_if_idle(room.pid) == :ok do
          TableSupervisor.stop_room(room.pid)
          %{state | rooms: Map.delete(state.rooms, room.room_id)}
        else
          put_room(state, room)
        end
    end
  end

  defp pick_room(state, setting) do
    state
    |> rooms_of(setting.id)
    |> Enum.filter(&open?/1)
    |> Enum.max_by(& &1.seats_taken, fn -> nil end)
  end

  # Открыт на регистрацию: ещё не начался и место есть. Стартовавший турнир
  # открытым не бывает — мест в нём нет по определению, а освободившихся
  # после вылета не существует: вылетевший остаётся за столом зрителем.
  defp open?(room) do
    not room.draining? and not room.started? and room.seats_taken < room.max_players
  end

  defp rooms_of(state, setting_id) do
    state.rooms
    |> Map.values()
    |> Enum.filter(&(&1.setting_id == setting_id))
    |> Enum.sort_by(& &1.room_id)
  end

  defp put_room(state, room), do: %{state | rooms: Map.put(state.rooms, room.room_id, room)}

  # --- витрина -------------------------------------------------------------

  defp build_snapshot(state, game_types) do
    state.settings
    |> Map.values()
    |> Enum.filter(&(&1.enabled and matches?(&1, game_types)))
    |> Enum.sort_by(&SitAndGoSetting.sort_key/1)
    |> Enum.map(&setting_snapshot(state, &1))
  end

  defp matches?(_setting, []), do: true
  defp matches?(setting, game_types), do: setting.game_type in game_types

  defp setting_snapshot(state, setting) do
    rooms = rooms_of(state, setting.id)

    %{
      setting: setting,
      # Сколько уже зарегистрировано в тот турнир, куда посадит вход:
      # именно это число игрок видит как «2/3» напротив строки.
      registered: registered(rooms),
      running: Enum.count(rooms, & &1.started?)
    }
  end

  defp registered(rooms) do
    rooms
    |> Enum.filter(&open?/1)
    |> Enum.map(& &1.seats_taken)
    |> Enum.max(fn -> 0 end)
  end

  defp broadcast_update(state, setting_id) do
    case Map.fetch(state.settings, setting_id) do
      :error ->
        :ok

      {:ok, setting} ->
        PubSub.broadcast(@pubsub, @topic, {:sit_n_go_update, setting_snapshot(state, setting)})
    end
  end

  defp schedule_reload(%{reload_ms: nil}), do: :ok
  defp schedule_reload(state), do: Process.send_after(self(), :reload, state.reload_ms)

  @doc false
  @spec room_state(Ecto.UUID.t()) :: term() | nil
  def room_state(room_id) do
    case TableRegistry.whereis(room_id) do
      nil -> nil
      pid -> TableServer.state(pid)
    end
  end
end
