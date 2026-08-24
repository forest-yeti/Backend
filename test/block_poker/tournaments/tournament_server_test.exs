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
  alias BlockPoker.Tournaments.TournamentServer
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
        assert TableServer.state(table).draining?
      end
    end

    test "конец перерыва возвращает столы в игру", ctx do
      %{pid: pid} = start_tournament(ctx.setting, 3)
      :ok = TournamentServer.start_tournament(pid)

      :ok = TournamentServer.fire(pid, :break)
      :ok = TournamentServer.fire(pid, :break_over)

      refute TournamentServer.state(pid).on_break

      for {_id, table} <- tables_of(pid) do
        refute TableServer.state(table).draining?
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

  describe "hand-for-hand на баббле" do
    # Сетка на два места: баббл наступает, когда живых трое.
    test "снапшот сообщает, идёт ли синхронный круг", ctx do
      %{pid: pid} = start_tournament(ctx.setting, 4)
      :ok = TournamentServer.start_tournament(pid)

      state = TournamentServer.state(pid)

      # Живых четверо, платят двоих — до баббла ещё один вылет.
      refute state.hand_for_hand
      assert state.next_payout_place == 2
    end

    test "число оплачиваемых мест считается по сетке при текущей явке", ctx do
      %{pid: pid} = start_tournament(ctx.setting, 4)
      :ok = TournamentServer.start_tournament(pid)

      assert TournamentServer.state(pid).next_payout_place == 2
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
