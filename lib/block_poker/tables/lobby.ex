defmodule BlockPoker.Tables.Lobby do
  @moduledoc """
  Единственный владелец пула комнат.

  Инвариант, который поддерживается всегда:

  > Для каждого включённого шаблона существует **ровно одна** комната
  > со свободными местами.

  Из него следуют оба направления сразу: заполнилась последняя свободная —
  открывается новая; опустела лишняя — закрывается. Формулировка через
  инвариант, а не через событие «заполнилась», выбрана потому, что событие
  легко обойти — выключением шаблона, падением комнаты, массовым уходом
  игроков, — а инвариант проверяется в одном месте после любого изменения
  состава и самовосстанавливается.

  Комната сама себя не порождает и не убивает: иначе две одновременно
  опустевшие комнаты обе решат, что вправе закрыться.
  """

  use GenServer

  require Logger

  alias BlockPoker.CashGames
  alias BlockPoker.CashGames.CashGameSetting
  alias BlockPoker.Tables.{LobbyQuery, RoomState, TableRegistry, TableServer, TableSupervisor}
  alias Phoenix.PubSub

  @pubsub BlockPoker.PubSub
  # Не "lobby": имя канала Phoenix занимает сам, и явная подписка канала
  # на тот же топик удваивала бы каждый lobby_delta.
  @topic "lobby_events"
  @default_reload_ms :timer.minutes(1)

  defmodule Room do
    @moduledoc false
    @enforce_keys [:room_id, :setting_id, :pid, :max_players]
    defstruct [:room_id, :setting_id, :pid, :max_players, seats_taken: 0, draining?: false]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Топик, в который уходят обновления лобби."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Перечитать шаблоны из БД и привести пул в соответствие.

  Нужен потому, что шаблоны правятся напрямую в БД (§8 задачи 3), а запись
  мимо приложения его не будит: под новые включённые шаблоны поднимаются
  комнаты, под выключенные — уходят в `:draining`.
  """
  @spec reload(GenServer.server()) :: :ok
  def reload(server \\ __MODULE__), do: GenServer.call(server, :reload)

  @doc "Агрегированная витрина лобби: шаблоны с их комнатами."
  @spec snapshot(GenServer.server(), LobbyQuery.t()) :: [map()]
  def snapshot(server \\ __MODULE__, query \\ %LobbyQuery{}) do
    GenServer.call(server, {:snapshot, query})
  end

  @doc "Комната со свободными местами для шаблона — по инварианту она одна."
  @spec open_room(GenServer.server(), Ecto.UUID.t()) ::
          {:ok, Ecto.UUID.t()} | {:error, :no_seats_available | :not_found}
  def open_room(server \\ __MODULE__, setting_id) do
    GenServer.call(server, {:open_room, setting_id})
  end

  @doc "Все комнаты шаблона — для `quick_seat`, которому нужен запасной вариант."
  @spec rooms_for(GenServer.server(), Ecto.UUID.t()) :: [Room.t()]
  def rooms_for(server \\ __MODULE__, setting_id) do
    GenServer.call(server, {:rooms_for, setting_id})
  end

  @spec settings(GenServer.server()) :: [CashGameSetting.t()]
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
    warn_about_zero_rake(state)
    schedule_reload(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    state = do_reload(state)
    {:reply, :ok, state}
  end

  def handle_call({:snapshot, query}, _from, state) do
    {:reply, build_snapshot(state, query), state}
  end

  def handle_call(:settings, _from, state), do: {:reply, Map.values(state.settings), state}

  def handle_call({:rooms_for, setting_id}, _from, state) do
    {:reply, rooms_of(state, setting_id), state}
  end

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
    state =
      state
      |> update_room(summary)
      |> enforce_invariant(summary.setting_id)

    broadcast_update(state, summary.setting_id)
    {:noreply, state}
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
    settings = Map.new(CashGames.list_settings(), &{&1.id, &1})
    state = %{state | settings: settings}
    state = Enum.reduce(Map.values(settings), state, &sync_setting(&2, &1))

    # Строку шаблона удалить нельзя, но она могла исчезнуть из выборки — тогда
    # её комнаты тоже надо увести в drain, иначе они останутся без владельца.
    orphans =
      state.rooms
      |> Map.values()
      |> Enum.reject(&Map.has_key?(settings, &1.setting_id))

    Enum.reduce(orphans, state, &drain_room(&2, &1))
  end

  defp sync_setting(state, %CashGameSetting{enabled: false} = setting) do
    state |> rooms_of(setting.id) |> Enum.reduce(state, &drain_room(&2, &1))
  end

  defp sync_setting(state, setting), do: enforce_invariant(state, setting.id)

  # Ядро всей конструкции: ровно одна комната со свободными местами.
  defp enforce_invariant(state, setting_id) do
    case Map.fetch(state.settings, setting_id) do
      :error -> state
      {:ok, %CashGameSetting{enabled: false}} -> state
      {:ok, setting} -> do_enforce(state, setting)
    end
  end

  defp do_enforce(state, setting) do
    rooms = rooms_of(state, setting.id)
    open = Enum.filter(rooms, &open?/1)

    cond do
      open == [] and length(rooms) < CashGameSetting.room_limit(setting) ->
        start_room(state, setting)

      # Лишние пустые комнаты закрываются: иначе после вечернего пика
      # останутся десятки пустых.
      length(open) > 1 ->
        close_extra(state, open)

      true ->
        state
    end
  end

  defp close_extra(state, open) do
    # Оставляем самую заполненную из свободных: игроки собираются в одну
    # комнату, а не размазываются по нескольким полупустым.
    keep = Enum.max_by(open, & &1.seats_taken)

    open
    |> Enum.reject(&(&1.room_id == keep.room_id))
    |> Enum.filter(&(&1.seats_taken == 0))
    |> Enum.reduce(state, &close_room(&2, &1))
  end

  defp start_room(state, setting) do
    room_id = Ecto.UUID.generate()
    opts = Keyword.merge(state.room_opts, room_id: room_id, setting: setting)

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
        Logger.error("не удалось поднять комнату шаблона #{setting.id}: #{inspect(reason)}")
        state
    end
  end

  defp close_room(state, room) do
    if room_closable?(room) do
      TableSupervisor.stop_room(room.pid)
      %{state | rooms: Map.delete(state.rooms, room.room_id)}
    else
      drain_room(state, room)
    end
  end

  # Комната с игроками, фишками или идущей раздачей не закрывается: она
  # помечается `:draining` и уходит по завершении.
  defp drain_room(state, room) do
    if room.draining? do
      state
    else
      TableServer.drain(room.pid)
      put_room(state, %{room | draining?: true})
    end
  end

  defp room_closable?(room), do: room.seats_taken == 0

  defp update_room(state, summary) do
    case Map.fetch(state.rooms, summary.room_id) do
      :error ->
        state

      {:ok, room} ->
        room = %{room | seats_taken: summary.seats_taken, draining?: summary.draining?}

        if room.draining? and room.seats_taken == 0 do
          TableSupervisor.stop_room(room.pid)
          %{state | rooms: Map.delete(state.rooms, room.room_id)}
        else
          put_room(state, room)
        end
    end
  end

  # Из свободных комнат берётся самая заполненная. На хедз-апе это и есть
  # требуемое исключение: игрок подсаживается к тому, кто уже ждёт соперника,
  # а не открывает вторую комнату и не садится ждать в одиночестве рядом.
  # На 6-max и 9-max то же правило просто собирает игроков в общую комнату.
  defp pick_room(state, setting) do
    state
    |> rooms_of(setting.id)
    |> Enum.filter(&open?/1)
    |> Enum.max_by(& &1.seats_taken, fn -> nil end)
  end

  defp open?(room), do: not room.draining? and room.seats_taken < room.max_players

  defp rooms_of(state, setting_id) do
    state.rooms
    |> Map.values()
    |> Enum.filter(&(&1.setting_id == setting_id))
    |> Enum.sort_by(& &1.room_id)
  end

  defp put_room(state, room), do: %{state | rooms: Map.put(state.rooms, room.room_id, room)}

  # --- витрина -------------------------------------------------------------

  defp build_snapshot(state, query) do
    state.settings
    |> Map.values()
    |> Enum.filter(&(&1.enabled and CashGameSetting.public?(&1)))
    |> Enum.map(&setting_snapshot(state, &1))
    |> then(&LobbyQuery.apply(query, &1))
  end

  defp setting_snapshot(state, setting) do
    rooms = rooms_of(state, setting.id)

    %{
      setting: setting,
      rooms: rooms,
      players_total: Enum.reduce(rooms, 0, &(&1.seats_taken + &2)),
      # Занятость лимита — заполненность комнаты, в которую посадит быстрый
      # вход: именно её игрок видит как «6/9» напротив строки лобби.
      seats_taken: featured_seats_taken(rooms),
      max_players: setting.max_players,
      limit_tier: LobbyQuery.limit_tier(setting),
      table_size: LobbyQuery.table_size(setting)
    }
  end

  defp featured_seats_taken(rooms) do
    rooms
    |> Enum.filter(&open?/1)
    |> Enum.map(& &1.seats_taken)
    |> Enum.max(fn -> 0 end)
  end

  defp broadcast_update(state, setting_id) do
    case Map.fetch(state.settings, setting_id) do
      :error ->
        :ok

      # Закрытой комнаты в общей сетке нет — значит, нет и её обновлений:
      # иначе подписчик лобби узнал бы о столе, которого не должен видеть.
      {:ok, setting} ->
        if CashGameSetting.public?(setting) do
          PubSub.broadcast(@pubsub, @topic, {:lobby_update, setting_snapshot(state, setting)})
        else
          :ok
        end
    end
  end

  defp schedule_reload(%{reload_ms: nil}), do: :ok
  defp schedule_reload(state), do: Process.send_after(self(), :reload, state.reload_ms)

  # Нулевой рейк — законное состояние сразу после сида, но забытая настройка
  # стоит руму всей выручки. Молчать об этом нельзя.
  defp warn_about_zero_rake(state) do
    state.settings
    |> Map.values()
    |> Enum.filter(&(&1.enabled and &1.currency == :main and &1.rake_percent == 0))
    |> Enum.each(fn setting ->
      Logger.warning(
        "шаблон #{CashGameSetting.display_name(setting)} на реальные деньги с нулевым рейком"
      )
    end)
  end

  @doc false
  @spec room_state(Ecto.UUID.t()) :: RoomState.t() | nil
  def room_state(room_id) do
    case TableRegistry.whereis(room_id) do
      nil -> nil
      pid -> TableServer.state(pid)
    end
  end
end
