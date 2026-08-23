defmodule BlockPoker.Tournaments.TournamentSchedulerTest do
  @moduledoc """
  Расписание → инстансы → старт.

  Часы инжектируются, тик прогоняется вручную: ждать минуту в тесте
  нельзя, а ждать час до анонса — тем более.
  """

  use BlockPoker.DataCase, async: false

  import BlockPoker.AccountsFixtures
  import BlockPoker.TournamentsFixtures

  alias BlockPoker.Tournaments
  alias BlockPoker.Tournaments.{Schedule, Tournament, TournamentScheduler, TournamentServer}
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(BlockPoker.Repo, {:shared, self()})
    on_exit(fn -> Sandbox.mode(BlockPoker.Repo, :manual) end)

    :ok
  end

  # Планировщик на фиксированных часах: тик видит ровно то время, которое
  # назвал тест.
  defp start_scheduler(now) do
    pid = start_supervised!({TournamentScheduler, tick_ms: nil, wall: fn -> now end})
    Sandbox.allow(BlockPoker.Repo, self(), pid)
    pid
  end

  defp schedule_fixture(setting, attrs) do
    {:ok, schedule} =
      %Schedule{tournament_setting_id: setting.id}
      |> Schedule.changeset(attrs)
      |> Repo.insert()

    schedule
  end

  defp instances do
    Tournament |> Repo.all() |> Enum.sort_by(& &1.starts_at)
  end

  describe "анонс" do
    test "создаёт инстанс на ближайший запуск в окне" do
      setting = setting_fixture(%{registration_opens_before: 3600})
      _schedule = schedule_fixture(setting, %{start_time: ~T[21:30:00], repeat: true})

      # 20:45 по Москве — до старта 45 минут, окно анонса уже открыто.
      scheduler = start_scheduler(~U[2026-09-01 17:45:00Z])
      :ok = TournamentScheduler.tick(scheduler)

      assert [tournament] = instances()
      assert DateTime.compare(tournament.starts_at, ~U[2026-09-01 18:30:00Z]) == :eq
    end

    test "до окна анонса не создаёт ничего" do
      setting = setting_fixture(%{registration_opens_before: 600})
      _schedule = schedule_fixture(setting, %{start_time: ~T[21:30:00], repeat: true})

      # За два часа до старта: окно анонса в десять минут ещё не открыто.
      scheduler = start_scheduler(~U[2026-09-01 16:30:00Z])
      :ok = TournamentScheduler.tick(scheduler)

      assert instances() == []
    end

    test "повторный тик не создаёт второго инстанса" do
      setting = setting_fixture()
      _schedule = schedule_fixture(setting, %{start_time: ~T[21:30:00], repeat: true})

      scheduler = start_scheduler(~U[2026-09-01 17:45:00Z])

      :ok = TournamentScheduler.tick(scheduler)
      :ok = TournamentScheduler.tick(scheduler)

      # Идемпотентность держит уникальный индекс, а не память тика.
      assert length(instances()) == 1
    end

    test "выключенное расписание не анонсируется" do
      setting = setting_fixture()

      _schedule =
        schedule_fixture(setting, %{start_time: ~T[21:30:00], repeat: true, enabled: false})

      scheduler = start_scheduler(~U[2026-09-01 17:45:00Z])
      :ok = TournamentScheduler.tick(scheduler)

      assert instances() == []
    end

    test "выключенный шаблон не поднимает новых запусков" do
      setting = setting_fixture(%{enabled: false})
      _schedule = schedule_fixture(setting, %{start_time: ~T[21:30:00], repeat: true})

      scheduler = start_scheduler(~U[2026-09-01 17:45:00Z])
      :ok = TournamentScheduler.tick(scheduler)

      assert instances() == []
    end

    test "недельное расписание срабатывает только в свой день" do
      setting = setting_fixture()
      # 5 сентября 2026 — суббота.
      _schedule = schedule_fixture(setting, %{start_time: ~T[21:30:00], repeat: true, weekday: 6})

      scheduler = start_scheduler(~U[2026-09-01 17:45:00Z])
      :ok = TournamentScheduler.tick(scheduler)

      assert instances() == []
    end
  end

  describe "открытие регистрации" do
    setup do
      setting = setting_fixture(%{registration_opens_before: 3600})
      schedule = schedule_fixture(setting, %{start_time: ~T[21:30:00], repeat: true})

      %{setting: setting, schedule: schedule}
    end

    test "анонсированный инстанс переходит в registering", ctx do
      scheduler = start_scheduler(~U[2026-09-01 17:45:00Z])
      :ok = TournamentScheduler.tick(scheduler)

      assert [tournament] = instances()
      assert tournament.status == :registering
      assert is_map(tournament.snapshot)

      # Процесс инстанса поднят: игрок должен видеть отсчёт до старта.
      assert TournamentServer.whereis(tournament.id)
    end

    test "снапшот настроек снят при открытии", ctx do
      scheduler = start_scheduler(~U[2026-09-01 17:45:00Z])
      :ok = TournamentScheduler.tick(scheduler)

      [tournament] = instances()

      assert length(tournament.snapshot["levels"]) == 2
    end

    test "отмена по недобору поставлена в очередь", ctx do
      scheduler = start_scheduler(~U[2026-09-01 17:45:00Z])
      :ok = TournamentScheduler.tick(scheduler)

      [tournament] = instances()

      # Джоба ставится при открытии регистрации, а не в момент старта:
      # она обязана пережить рестарт ноды.
      assert [job] = Repo.all(Oban.Job)
      assert job.args["tournament_id"] == tournament.id
    end
  end

  describe "старт по часам" do
    setup do
      setting = setting_fixture(%{registration_opens_before: 3600, min_players: 2})
      schedule = schedule_fixture(setting, %{start_time: ~T[21:30:00], repeat: true})

      %{setting: setting, schedule: schedule}
    end

    test "набравший минимум стартует", ctx do
      scheduler = start_scheduler(~U[2026-09-01 17:45:00Z])
      :ok = TournamentScheduler.tick(scheduler)

      [tournament] = instances()

      for _index <- 1..2 do
        {:ok, _entry} = Tournaments.register(tournament.id, user_fixture().id)
      end

      # Момент старта настал.
      later = start_scheduler_at(~U[2026-09-01 18:30:00Z])
      :ok = TournamentScheduler.tick(later)

      {:ok, reloaded} = Tournaments.get_tournament(tournament.id)
      assert reloaded.status == :running
    end

    test "недобравший остаётся ждать отмены, а не падает", ctx do
      scheduler = start_scheduler(~U[2026-09-01 17:45:00Z])
      :ok = TournamentScheduler.tick(scheduler)

      [tournament] = instances()
      {:ok, _entry} = Tournaments.register(tournament.id, user_fixture().id)

      later = start_scheduler_at(~U[2026-09-01 18:30:00Z])
      :ok = TournamentScheduler.tick(later)

      {:ok, reloaded} = Tournaments.get_tournament(tournament.id)
      assert reloaded.status == :registering
    end

    test "до времени старта не стартует", ctx do
      scheduler = start_scheduler(~U[2026-09-01 17:45:00Z])
      :ok = TournamentScheduler.tick(scheduler)

      [tournament] = instances()

      for _index <- 1..2 do
        {:ok, _entry} = Tournaments.register(tournament.id, user_fixture().id)
      end

      :ok = TournamentScheduler.tick(scheduler)

      {:ok, reloaded} = Tournaments.get_tournament(tournament.id)
      assert reloaded.status == :registering
    end
  end

  # Второй планировщик на другом времени: так тест перематывает часы,
  # не трогая уже поднятые процессы.
  defp start_scheduler_at(now) do
    pid =
      start_supervised!(
        {TournamentScheduler, tick_ms: nil, wall: fn -> now end, name: :"scheduler_#{now}"},
        id: {TournamentScheduler, now}
      )

    Sandbox.allow(BlockPoker.Repo, self(), pid)
    pid
  end
end
