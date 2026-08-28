defmodule BlockPoker.Admin.GamesTest do
  @moduledoc """
  Уровень 4: вмешательство панели в идущий турнир — пауза, возобновление,
  снятие.

  Турнир и столы поднимаются настоящие: проверять здесь нечего, если
  процессов нет, — вся суть операций в том, что они доходят до столов.
  """

  use BlockPoker.DataCase, async: false

  import BlockPoker.AccountsFixtures
  import BlockPoker.AdminFixtures
  import BlockPoker.TournamentsFixtures

  alias BlockPoker.Admin
  alias BlockPoker.Admin.AdminAudit
  alias BlockPoker.Tables.TableServer
  alias BlockPoker.Tournaments
  alias BlockPoker.Tournaments.{Tournament, TournamentServer}
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(BlockPoker.Repo, {:shared, self()})
    on_exit(fn -> Sandbox.mode(BlockPoker.Repo, :manual) end)

    setting = setting_fixture(%{table_size: 6, min_players: 2})

    Map.merge(admin_with_ctx(), %{setting: setting})
  end

  defp running_tournament(setting, player_count \\ 3) do
    tournament = tournament_fixture(setting)

    users =
      for _index <- 1..player_count do
        user = user_fixture()
        {:ok, _entry} = Tournaments.register(tournament.id, user.id)
        user
      end

    pid =
      start_supervised!(
        {TournamentServer, [tournament_id: tournament.id]},
        id: {TournamentServer, tournament.id}
      )

    Sandbox.allow(BlockPoker.Repo, self(), pid)
    :ok = TournamentServer.start_tournament(pid)

    %{tournament: tournament, users: users, pid: pid}
  end

  defp audit_rows(action) do
    Repo.all(from(a in AdminAudit, where: a.action == ^action))
  end

  describe "пауза" do
    test "останавливает столы и пишет причину в журнал", ctx do
      %{tournament: tournament, pid: pid} = running_tournament(ctx.setting)

      assert {:ok, card} = Admin.pause_tournament(ctx.ctx, tournament.id, "разбор жалобы")

      assert card.extra.paused

      for {_id, table} <- :sys.get_state(pid).tables do
        assert TableServer.state(table).paused?
      end

      assert [row] = audit_rows(:pause_tournament)
      assert row.subject_type == :tournament
      assert row.subject_id == tournament.id
      assert row.reason == "разбор жалобы"
    end

    test "без причины не останавливает вовсе", ctx do
      %{tournament: tournament, pid: pid} = running_tournament(ctx.setting)

      assert {:error, :admin_reason_required} =
               Admin.pause_tournament(ctx.ctx, tournament.id, nil)

      # Ни паузы, ни записи: проверка причины идёт до действия.
      refute TournamentServer.state(pid).paused
      assert audit_rows(:pause_tournament) == []
    end

    test "возобновление возвращает столы в игру", ctx do
      %{tournament: tournament, pid: pid} = running_tournament(ctx.setting)

      {:ok, _card} = Admin.pause_tournament(ctx.ctx, tournament.id, "разбор жалобы")

      assert {:ok, card} = Admin.resume_tournament(ctx.ctx, tournament.id, "разобрались")
      refute card.extra.paused

      for {_id, table} <- :sys.get_state(pid).tables do
        refute TableServer.state(table).paused?
      end

      assert [row] = audit_rows(:resume_tournament)
      assert row.reason == "разобрались"
    end

    test "турнир без процесса остановить нечем", ctx do
      tournament = tournament_fixture(ctx.setting)

      assert {:error, :tournament_not_running} =
               Admin.pause_tournament(ctx.ctx, tournament.id, "причина")
    end
  end

  describe "снятие" do
    test "снимает турнир, гасит столы и пишет журнал", ctx do
      %{tournament: tournament, pid: pid} = running_tournament(ctx.setting)
      tables = :sys.get_state(pid).tables

      assert {:ok, result} = Admin.cancel_tournament(ctx.ctx, tournament.id, "инцидент")
      assert result.status == :cancelled
      assert result.refunded == 3

      {:ok, fresh} = Tournaments.get_tournament(tournament.id)
      assert fresh.status == :cancelled

      for {_id, table} <- tables, do: refute(Process.alive?(table))

      assert [row] = audit_rows(:cancel_tournament)
      assert row.reason == "инцидент"
      assert row.meta["refunded"] == 3
    end

    @tag :capture_log
    test "снимает и турнир, чей процесс не поднялся", ctx do
      # Тот самый случай, ради которого ручка и нужна: в БД турнир идёт,
      # раздавать некому, и снять его иначе нечем.
      %{tournament: tournament} = running_tournament(ctx.setting)
      stop_supervised!({TournamentServer, tournament.id})

      assert {:ok, result} = Admin.cancel_tournament(ctx.ctx, tournament.id, "висяк")
      assert result.refunded == 3

      {:ok, fresh} = Tournaments.get_tournament(tournament.id)
      assert fresh.status == :cancelled
      refute Tournament.paused?(fresh)
    end

    test "снять не начавшийся турнир этой ручкой нельзя", ctx do
      tournament = tournament_fixture(ctx.setting)

      # Не начавшийся отменяется своей отменой, с другими правилами
      # возврата: здесь честнее отказ, чем тихая подмена операции.
      assert {:error, :tournament_not_running} =
               Admin.cancel_tournament(ctx.ctx, tournament.id, "причина")
    end
  end
end
