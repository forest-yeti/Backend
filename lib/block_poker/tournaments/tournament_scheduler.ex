defmodule BlockPoker.Tournaments.TournamentScheduler do
  @moduledoc """
  Превращает расписание в инстансы и запускает их по часам.

  Тикает раз в минуту и делает на каждом тике три вещи:

    1. смотрит окно `[сейчас, сейчас + самое раннее открытие регистрации]`
       и создаёт анонсы для запусков, которые в него попали;
    2. открывает регистрацию тем, у кого подошёл срок, и поднимает под
       них `TournamentServer`;
    3. стартует те, у кого настало время, и ставит отмену недобравшим.

  ## Почему тик, а не таймер на каждый запуск

  Таймер пришлось бы восстанавливать после каждого рестарта ноды и
  отменять при правке расписания оператором. Тик не помнит ничего: он
  смотрит на состояние и доводит его до нужного. Пропущенный из-за
  перезагрузки момент он подберёт на следующей минуте — для турнира,
  который анонсируется за час, это незаметно.

  Идемпотентность обеспечивает не код, а уникальный индекс
  `(schedule_id, starts_at)`: сколько бы раз тик ни сработал, второго
  инстанса на тот же вечер не появится.

  ## Часы инжектируются

  Как и у `TournamentServer`: тесты прогоняют тик руками на заданном
  времени, а не ждут минуты (§11 CLAUDE.md).
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias BlockPoker.Repo
  alias BlockPoker.Tournaments
  alias BlockPoker.Tournaments.{Schedule, Tournament, TournamentServer, TournamentSupervisor}
  alias BlockPoker.Tournaments.Workers.CancelUnderfilled

  @default_tick_ms :timer.minutes(1)

  defmodule State do
    @moduledoc false
    defstruct [:tick_ms, :wall, :timer]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    # Имя перекрывается опцией ради тестов: им нужно два планировщика на
    # разных часах, чтобы перемотать время, не трогая живые процессы.
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Прогоняет тик немедленно и дожидается его конца.

  Существует ради тестов и ради оператора, который только что завёл
  расписание и не хочет ждать минуту.
  """
  @spec tick(GenServer.server()) :: :ok
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick, 30_000)

  @impl true
  def init(opts) do
    state = %State{
      tick_ms: Keyword.get(opts, :tick_ms, @default_tick_ms),
      wall: Keyword.get(opts, :wall, &DateTime.utc_now/0)
    }

    {:ok, schedule_next(state)}
  end

  @impl true
  def handle_call(:tick, _from, state) do
    run(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    run(state)
    {:noreply, schedule_next(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_next(%State{tick_ms: nil} = state), do: state

  defp schedule_next(state) do
    %{state | timer: Process.send_after(self(), :tick, state.tick_ms)}
  end

  # --- Тик -----------------------------------------------------------------

  defp run(state) do
    now = state.wall.()

    announce_upcoming(now)
    open_registrations(now)
    start_due(now)
  rescue
    error ->
      # Тик не имеет права уронить планировщик: следующий разберётся
      # с тем же состоянием. Падение здесь означало бы, что весь рум
      # остался без турниров из-за одной кривой строки расписания.
      Logger.error("тик планировщика турниров упал: #{inspect(error)}")
  end

  # --- Анонс ---------------------------------------------------------------

  defp announce_upcoming(now) do
    for schedule <- enabled_schedules(),
        starts_at <- Schedule.occurrences(schedule, now, horizon(now, schedule)) do
      case Tournaments.ensure_instance(schedule, starts_at) do
        {:ok, tournament} ->
          Logger.info("анонсирован турнир #{tournament.id} на #{starts_at}")

        {:already_exists, _tournament} ->
          :ok

        {:error, reason} ->
          Logger.error("не удалось анонсировать запуск #{starts_at}: #{inspect(reason)}")
      end
    end
  end

  # Окно анонса — ровно то, за сколько до старта инстанс должен появиться
  # в лобби. У каждого шаблона своё, поэтому считается по шаблону, а не
  # общей константой.
  defp horizon(now, %Schedule{setting: setting}) do
    DateTime.add(now, setting.registration_opens_before, :second)
  end

  defp enabled_schedules do
    Schedule
    |> where([s], s.enabled == true)
    |> join(:inner, [s], t in assoc(s, :setting))
    |> where([_s, t], t.enabled == true)
    |> preload(:setting)
    |> Repo.all()
  end

  # --- Открытие регистрации ------------------------------------------------

  defp open_registrations(now) do
    for tournament <- due_to_open(now) do
      case Tournaments.open_registration(tournament) do
        {:ok, opened} ->
          # Процесс инстанса здесь **не** поднимается: пустому турниру он
          # не нужен, а рум анонсирует их сотнями в сутки. Поднимет его
          # первая регистрация (см. `Tournaments`) или старт ниже.
          schedule_cancel(opened)

        {:error, reason} ->
          Logger.error("не открылась регистрация #{tournament.id}: #{inspect(reason)}")
      end
    end
  end

  defp due_to_open(now) do
    Tournament
    |> where([t], t.status == :announced)
    |> preload(setting: [:blind_levels, payout_rows: :ticket])
    |> Repo.all()
    |> Enum.filter(fn tournament ->
      opens_at = Tournament.registration_opens_at(tournament, tournament.setting)
      DateTime.compare(now, opens_at) != :lt
    end)
  end

  # Отмена по недобору ставится **сразу при открытии регистрации**, а не
  # в момент старта: джоба обязана пережить рестарт ноды, и заводить её
  # в последнюю секунду значило бы потерять её при перезагрузке.
  defp schedule_cancel(tournament) do
    deadline = Tournament.cancel_deadline(tournament, tournament.setting)

    case CancelUnderfilled.schedule(tournament, deadline) do
      {:ok, _job} -> :ok
      {:error, reason} -> Logger.error("не поставлена отмена: #{inspect(reason)}")
    end
  end

  # --- Старт ---------------------------------------------------------------

  defp start_due(now) do
    for tournament <- due_to_start(now) do
      ensure_server(tournament)

      case TournamentServer.start_tournament(tournament.id) do
        :ok ->
          Logger.info("турнир #{tournament.id} стартовал")

        # Минимум не набран — это не ошибка планировщика: турнир ждёт
        # своей отмены, которая уже стоит в очереди.
        {:error, :not_enough_players} ->
          :ok

        {:error, reason} ->
          Logger.error("турнир #{tournament.id} не стартовал: #{inspect(reason)}")
      end
    end
  end

  defp due_to_start(now) do
    Tournament
    |> where([t], t.status == :registering and t.starts_at <= ^now)
    |> preload(setting: [:blind_levels, payout_rows: :ticket])
    |> Repo.all()
  end

  # --- Процессы ------------------------------------------------------------

  # Инстанс поднимается первой регистрацией и живёт до конца турнира;
  # здесь он подстраховывается на старте. Повторный вызов безвреден:
  # процесс уже есть.
  defp ensure_server(%Tournament{} = tournament) do
    if TournamentServer.whereis(tournament.id) do
      :ok
    else
      case TournamentSupervisor.start_tournament(tournament_id: tournament.id) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> Logger.error("не поднялся турнир: #{inspect(reason)}")
      end
    end
  end
end
