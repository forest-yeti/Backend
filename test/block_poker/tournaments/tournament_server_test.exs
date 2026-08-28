defmodule BlockPoker.Tournaments.TournamentServerTest do
  @moduledoc """
  Процесс турнира: старт, рассадка, уровни, перерывы, вылеты, финалка.

  Часы инжектируются, `Process.sleep` не используется (§11 CLAUDE.md):
  таймеры прогоняются вручную через `fire/2`. Реальное время здесь
  сделало бы тесты и медленными, и флаки — уровень длится десять минут.

  Столы поднимаются настоящие: турнир без `TableServer` проверять
  бессмысленно, потому что вся его работа — распоряжаться ими.
  """

  use BlockPoker.DataCase, async: false

  import BlockPoker.AccountsFixtures
  import BlockPoker.TournamentsFixtures

  alias BlockPoker.Tables.TableServer
  alias BlockPoker.Tournaments
  alias BlockPoker.Tournaments.{Tournament, TournamentServer}
  alias BlockPoker.Wallet
  alias Ecto.Adapters.SQL.Sandbox

  setup tags do
    # Столы и турнир — отдельные процессы, и все они ходят в БД:
    # Sandbox обязан быть общим.
    Sandbox.mode(BlockPoker.Repo, {:shared, self()})

    on_exit(fn -> Sandbox.mode(BlockPoker.Repo, :manual) end)

    setting =
      setting_fixture(Map.merge(%{table_size: 6, min_players: 2}, tags[:setting] || %{}))

    %{setting: setting}
  end

  defp start_tournament(setting, player_count, opts \\ []) do
    tournament = tournament_fixture(setting)

    users = for _index <- 1..player_count, do: user_fixture()

    for user <- users do
      {:ok, _entry} = Tournaments.register(tournament.id, user.id)
    end

    {:ok, pid} = start_server(Keyword.merge([tournament_id: tournament.id], opts))

    %{tournament: tournament, users: users, pid: pid}
  end

  # Поднимаем процесс под тестовым супервизором, а не под турнирным:
  # так он гаснет вместе с тестом и не переживает его.
  defp start_server(opts) do
    pid =
      start_supervised!({TournamentServer, opts}, id: {TournamentServer, opts[:tournament_id]})

    Sandbox.allow(BlockPoker.Repo, self(), pid)
    {:ok, pid}
  end

  describe "старт" do
    test "поднимает столы и рассаживает зарегистрированных", ctx do
      %{pid: pid} = start_tournament(ctx.setting, 4)

      assert :ok = TournamentServer.start_tournament(pid)

      state = TournamentServer.state(pid)

      assert state.status == :running
      assert state.tables == 1
      assert state.players_left == 4
    end

    test "явка на два стола поднимает два стола", ctx do
      %{pid: pid} = start_tournament(ctx.setting, 8)

      :ok = TournamentServer.start_tournament(pid)

      assert TournamentServer.state(pid).tables == 2
    end

    test "столы заполняются равномерно, а не «полные плюс огрызок»", ctx do
      %{pid: pid} = start_tournament(ctx.setting, 8)

      :ok = TournamentServer.start_tournament(pid)

      counts = table_occupancies(pid)

      assert Enum.sort(counts) == [4, 4]
    end

    test "недобор не стартует турнир" do
      setting = setting_fixture(%{table_size: 6, min_players: 3})
      %{pid: pid} = start_tournament(setting, 2)

      assert {:error, :not_enough_players} = TournamentServer.start_tournament(pid)
    end

    test "повторный старт отвергается", ctx do
      %{pid: pid} = start_tournament(ctx.setting, 3)

      :ok = TournamentServer.start_tournament(pid)

      assert {:error, :tournament_started} = TournamentServer.start_tournament(pid)
    end

    test "инстанс в БД переходит в running", ctx do
      %{pid: pid, tournament: tournament} = start_tournament(ctx.setting, 3)

      :ok = TournamentServer.start_tournament(pid)

      {:ok, reloaded} = Tournaments.get_tournament(tournament.id)
      assert reloaded.status == :running
      assert reloaded.started_at
    end

    test "посаженные входы переходят в playing", ctx do
      %{pid: pid, tournament: tournament} = start_tournament(ctx.setting, 3)

      :ok = TournamentServer.start_tournament(pid)

      # Без этого статуса чипсчёт отдаёт строку игрока как `registered`,
      # и клиент не узнаёт свой стол: `table_id` он берёт только из
      # строки играющего входа.
      {:ok, card} = Tournaments.card(tournament.id)

      assert Enum.all?(card.chip_counts.entries, &(&1.status == :playing))
      assert Enum.all?(card.chip_counts.entries, &(&1.table_id != nil))
    end

    test "карточка показывает призовые до закрытия поздней регистрации", ctx do
      %{pid: pid, tournament: tournament} = start_tournament(ctx.setting, 3)

      # До старта фонд ещё не зафиксирован (`prize_pool` = 0), но взносы
      # собраны — сетка обязана считаться по ним, а не показывать нули.
      {:ok, before} = Tournaments.card(tournament.id)

      assert before.payouts != []
      assert Enum.all?(before.payouts, &(&1.amount > 0 or &1.ticket_value > 0))

      :ok = TournamentServer.start_tournament(pid)

      {:ok, running} = Tournaments.card(tournament.id)

      assert Enum.map(running.payouts, & &1.amount) == Enum.map(before.payouts, & &1.amount)
    end

    test "поздняя регистрация закрывается концом ребайных уровней", ctx do
      %{pid: pid, tournament: tournament} = start_tournament(ctx.setting, 3)

      :ok = TournamentServer.start_tournament(pid)

      {:ok, reloaded} = Tournaments.get_tournament(tournament.id)

      # Первый уровень ребайный и длится 600 секунд — значит вход закрыт
      # через десять минут после старта, а не «через уровень номер N».
      assert reloaded.late_reg_until
      assert DateTime.diff(reloaded.late_reg_until, DateTime.utc_now()) in 590..600
    end
  end

  describe "уровни" do
    test "повышение меняет уровень турнира", ctx do
      %{pid: pid} = start_tournament(ctx.setting, 3)
      :ok = TournamentServer.start_tournament(pid)

      assert TournamentServer.state(pid).level == 1

      :ok = TournamentServer.fire(pid, :level)

      assert TournamentServer.state(pid).level == 2
    end

    test "новые номиналы доезжают до столов", ctx do
      %{pid: pid} = start_tournament(ctx.setting, 3)
      :ok = TournamentServer.start_tournament(pid)

      :ok = TournamentServer.fire(pid, :level)

      # Стол применяет уровень, названный турниром, а не считает свой.
      for {_id, table} <- tables_of(pid) do
        assert TableServer.state(table).tournament.level == 2
      end
    end

    test "часы уровня стоят на перерыве", ctx do
      # Часы под контролем теста: уровень длится десять минут, и весь
      # смысл проверки — что эти десять минут считаются игровым
      # временем, а не стенным.
      clock = start_supervised!({Agent, fn -> 0 end}, id: :level_clock)
      now = fn -> Agent.get(clock, & &1) end
      advance = fn ms -> Agent.update(clock, &(&1 + ms)) end

      %{pid: pid} = start_tournament(ctx.setting, 3, monotonic: now)
      :ok = TournamentServer.start_tournament(pid)

      # Минута игры...
      advance.(60_000)
      :ok = TournamentServer.fire(pid, :break)

      # ...и пять минут перерыва, которые уровню не засчитываются.
      advance.(300_000)
      :ok = TournamentServer.fire(pid, :break_over)

      state = :sys.get_state(pid)

      assert state.level == 1
      assert state.level_elapsed_ms == 60_000
    end

    test "снимок несёт остаток уровня, а не момент повышения", ctx do
      clock = start_supervised!({Agent, fn -> 0 end}, id: :remaining_clock)
      now = fn -> Agent.get(clock, & &1) end
      advance = fn ms -> Agent.update(clock, &(&1 + ms)) end

      %{pid: pid} = start_tournament(ctx.setting, 3, monotonic: now)
      :ok = TournamentServer.start_tournament(pid)

      # Уровень длится десять минут: минута игры — девять в остатке.
      advance.(60_000)
      assert TournamentServer.state(pid).next_level_in_ms == 540_000

      # На перерыве часы стоят, и отсчитывать нечего: `nil`, а не ноль —
      # клиент рисует это отсутствием счётчика, а не «повышение сейчас».
      :ok = TournamentServer.fire(pid, :break)
      assert TournamentServer.state(pid).next_level_in_ms == nil

      # Перерыв уровню не засчитывается: остаток тот же самый.
      advance.(300_000)
      :ok = TournamentServer.fire(pid, :break_over)
      assert TournamentServer.state(pid).next_level_in_ms == 540_000
    end

    test "снимок несёт структуру уровней с флагами входа", ctx do
      %{pid: pid} = start_tournament(ctx.setting, 3)
      :ok = TournamentServer.start_tournament(pid)

      state = TournamentServer.state(pid)

      refute state.levels == []
      assert %{rebuy_allowed: _rebuy, addon_allowed: _addon} = state.level_flags[1]
    end

    test "уровень турнира виден в снапшоте номиналами", ctx do
      %{pid: pid} = start_tournament(ctx.setting, 3)
      :ok = TournamentServer.start_tournament(pid)

      :ok = TournamentServer.fire(pid, :level)

      assert %{small_blind: 50, big_blind: 100, ante: 10} = TournamentServer.state(pid).limits
    end
  end

  describe "перерывы" do
    test "перерыв останавливает столы", ctx do
      %{pid: pid} = start_tournament(ctx.setting, 3)
      :ok = TournamentServer.start_tournament(pid)

      :ok = TournamentServer.fire(pid, :break)

      assert TournamentServer.state(pid).on_break

      # Стол на перерыве новых раздач не начинает.
      for {_id, table} <- tables_of(pid) do
        assert TableServer.state(table).paused?
      end
    end

    test "конец перерыва возвращает столы в игру", ctx do
      %{pid: pid} = start_tournament(ctx.setting, 3)
      :ok = TournamentServer.start_tournament(pid)

      :ok = TournamentServer.fire(pid, :break)
      :ok = TournamentServer.fire(pid, :break_over)

      refute TournamentServer.state(pid).on_break

      for {_id, table} <- tables_of(pid) do
        refute TableServer.state(table).paused?
      end
    end

    test "повторный вход в перерыв ничего не ломает", ctx do
      %{pid: pid} = start_tournament(ctx.setting, 3)
      :ok = TournamentServer.start_tournament(pid)

      :ok = TournamentServer.fire(pid, :break)
      :ok = TournamentServer.fire(pid, :break)

      assert TournamentServer.state(pid).on_break
    end
  end

  describe "пауза" do
    test "останавливает столы и часы уровня", ctx do
      clock = start_supervised!({Agent, fn -> 0 end}, id: :pause_clock)
      now = fn -> Agent.get(clock, & &1) end
      advance = fn ms -> Agent.update(clock, &(&1 + ms)) end

      %{pid: pid} = start_tournament(ctx.setting, 3, monotonic: now)
      :ok = TournamentServer.start_tournament(pid)

      advance.(60_000)
      :ok = TournamentServer.pause(pid)

      state = TournamentServer.state(pid)
      assert state.paused

      # Часы уровня встали: остаток не отсчитывается, пока никто не играет.
      assert state.next_level_in_ms == nil

      for {_id, table} <- tables_of(pid) do
        assert TableServer.state(table).paused?
      end
    end

    test "снятие паузы отдаёт уровню его остаток, а не начинает заново", ctx do
      clock = start_supervised!({Agent, fn -> 0 end}, id: :pause_clock)
      now = fn -> Agent.get(clock, & &1) end
      advance = fn ms -> Agent.update(clock, &(&1 + ms)) end

      %{pid: pid} = start_tournament(ctx.setting, 3, monotonic: now)
      :ok = TournamentServer.start_tournament(pid)

      advance.(60_000)
      :ok = TournamentServer.pause(pid)

      # Час простоя уровню не засчитывается: он не игровое время.
      advance.(3_600_000)
      :ok = TournamentServer.resume(pid)

      state = TournamentServer.state(pid)
      refute state.paused
      assert state.level == 1

      # Уровень длится десять минут, минута из них сыграна.
      assert state.next_level_in_ms == 540_000

      for {_id, table} <- tables_of(pid) do
        refute TableServer.state(table).paused?
      end
    end

    test "пауза записана в БД и переживает перезапуск процесса", ctx do
      %{pid: pid, tournament: tournament} = start_tournament(ctx.setting, 3)
      :ok = TournamentServer.start_tournament(pid)
      :ok = TournamentServer.pause(pid)

      assert Tournaments.get_tournament(tournament.id) |> elem(1) |> Tournament.paused?()

      stop_supervised!({TournamentServer, tournament.id})

      {:ok, restarted} = start_server(tournament_id: tournament.id)

      # Поднявшийся заново турнир остаётся остановленным: иначе рестарт
      # ноды снимал бы паузу сам собой.
      assert TournamentServer.state(restarted).paused

      for {_id, table} <- tables_of(restarted) do
        assert TableServer.state(table).paused?
      end
    end

    test "остановленный турнир не поднимает уровень по таймеру", ctx do
      %{pid: pid} = start_tournament(ctx.setting, 3)
      :ok = TournamentServer.start_tournament(pid)
      :ok = TournamentServer.pause(pid)

      # Таймер уровня снят вместе с паузой — будить некого.
      assert :sys.get_state(pid).level_timer == nil
    end

    test "повторная пауза и повторное снятие идемпотентны", ctx do
      %{pid: pid} = start_tournament(ctx.setting, 3)
      :ok = TournamentServer.start_tournament(pid)

      :ok = TournamentServer.pause(pid)
      :ok = TournamentServer.pause(pid)
      assert TournamentServer.state(pid).paused

      :ok = TournamentServer.resume(pid)
      :ok = TournamentServer.resume(pid)
      refute TournamentServer.state(pid).paused
    end

    test "недоигранный перерыв продолжается после паузы, а не начинается заново", ctx do
      %{pid: pid} = start_tournament(ctx.setting, 3)
      :ok = TournamentServer.start_tournament(pid)

      :ok = TournamentServer.fire(pid, :break)
      :ok = TournamentServer.pause(pid)
      :ok = TournamentServer.resume(pid)

      state = TournamentServer.state(pid)

      # Перерыв ещё идёт: столы остаются стоять, и снятие паузы их не
      # поднимает — иначе турнир раздавал бы посреди перерыва.
      assert state.on_break
      assert state.break_ends_in_ms <= 300_000

      for {_id, table} <- tables_of(pid) do
        assert TableServer.state(table).paused?
      end
    end

    test "перерыв, кончившийся во время паузы, не удлиняется ею", ctx do
      # Стенные часы под контролем теста: перерыв отсчитывается ими, и
      # проверка ровно в том, что пауза их не останавливает.
      clock = start_supervised!({Agent, fn -> DateTime.utc_now() end}, id: :break_wall)
      wall = fn -> Agent.get(clock, & &1) end
      advance = fn sec -> Agent.update(clock, &DateTime.add(&1, sec, :second)) end

      %{pid: pid} = start_tournament(ctx.setting, 3, wall: wall)
      :ok = TournamentServer.start_tournament(pid)

      :ok = TournamentServer.fire(pid, :break)
      :ok = TournamentServer.pause(pid)

      # Пять минут прошли, пока турнир стоял: отдых игроки получили.
      advance.(301)
      :ok = TournamentServer.resume(pid)

      refute TournamentServer.state(pid).on_break

      for {_id, table} <- tables_of(pid) do
        refute TableServer.state(table).paused?
      end
    end
  end

  describe "снятие турнира" do
    test "возвращает взносы, гасит столы и кончает процесс", ctx do
      %{pid: pid, tournament: tournament, users: users} = start_tournament(ctx.setting, 3)
      :ok = TournamentServer.start_tournament(pid)

      tables = tables_of(pid)
      ref = Process.monitor(pid)

      assert {:ok, 3} = TournamentServer.abort(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      {:ok, fresh} = Tournaments.get_tournament(tournament.id)
      assert fresh.status == :cancelled

      # Столы турнира гаснут вместе с ним: играть за ними больше не за что.
      for {_id, table} <- tables, do: refute(Process.alive?(table))

      # Взнос вернулся каждому: снятый турнир призов не разыграл.
      for user <- users do
        {:ok, wallet} = Wallet.get_wallet(user.id, ctx.setting.currency)
        assert wallet.amount == Wallet.play_money_default()
      end
    end

    test "снять можно только идущий турнир", ctx do
      %{pid: pid} = start_tournament(ctx.setting, 3)

      # Регистрация ещё открыта: это отмена (`cancel/1`), а не снятие.
      assert {:error, :tournament_not_running} = TournamentServer.abort(pid)
    end
  end

  describe "hand-for-hand на баббле" do
    # Сетка на два места: баббл наступает, когда живых трое.
    test "снапшот сообщает, идёт ли синхронный круг", ctx do
      %{pid: pid} = start_tournament(ctx.setting, 4)
      :ok = TournamentServer.start_tournament(pid)

      state = TournamentServer.state(pid)

      # Живых четверо, платят двоих — до баббла ещё один вылет.
      refute state.hand_for_hand
      assert state.paid_places == 2
    end

    test "число оплачиваемых мест считается по сетке при текущей явке", ctx do
      %{pid: pid} = start_tournament(ctx.setting, 4)
      :ok = TournamentServer.start_tournament(pid)

      assert TournamentServer.state(pid).paid_places == 2
    end
  end

  describe "снапшот" do
    test "несёт счётчики, а не список участников", ctx do
      %{pid: pid} = start_tournament(ctx.setting, 4)
      :ok = TournamentServer.start_tournament(pid)

      state = TournamentServer.state(pid)

      # Полный чипсчёт живёт в карточке лобби: при трёхстах участниках
      # каждый вылет рассылал бы триста строк каждому.
      assert state.players_left == 4
      assert state.entries == 4
      refute Map.has_key?(state, :players)
      refute Map.has_key?(state, :chip_counts)
    end
  end

  defp tables_of(pid) do
    :sys.get_state(pid).tables
  end

  defp table_occupancies(pid) do
    for {_id, table} <- tables_of(pid) do
      table |> TableServer.state() |> BlockPoker.Tables.RoomState.seats_taken()
    end
  end
end
