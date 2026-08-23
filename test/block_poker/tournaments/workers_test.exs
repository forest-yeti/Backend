defmodule BlockPoker.Tournaments.WorkersTest do
  @moduledoc """
  Фоновые задачи турниров.

  Джобы проверяются прямым вызовом `perform/1`, а не через очередь:
  очередь — это Oban, и её работоспособность не наша ответственность.
  Наша — то, что джоба делает с деньгами и билетами.

  Отдельно проверяется **повторное выполнение**: джоба может выполниться
  дважды после рестарта ноды, и ни одна из них не имеет права ни списать
  дважды, ни отменить начавшийся турнир.
  """

  use BlockPoker.DataCase, async: true

  import BlockPoker.AccountsFixtures
  import BlockPoker.TournamentsFixtures

  alias BlockPoker.Tickets
  alias BlockPoker.Tournaments
  alias BlockPoker.Tournaments.Workers.{CancelUnderfilled, ExpireTickets, SettleTournament}
  alias BlockPoker.Wallet

  defp balance(user) do
    {:ok, wallet} = Wallet.get_wallet(user.id, :play_money)
    wallet.amount
  end

  defp job(args), do: %Oban.Job{args: args}

  describe "истечение билетов" do
    test "гасит просроченные" do
      setting = setting_fixture()
      user = user_fixture()
      ticket = ticket_fixture(setting)

      _expired =
        user_ticket_fixture(ticket, user, %{
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      assert :ok = ExpireTickets.perform(job(%{}))
      assert Tickets.list_active(user.id) == []
    end

    test "годные не трогает" do
      setting = setting_fixture()
      user = user_fixture()
      _alive = user_ticket_fixture(ticket_fixture(setting), user)

      assert :ok = ExpireTickets.perform(job(%{}))
      assert length(Tickets.list_active(user.id)) == 1
    end

    test "повторный прогон безопасен" do
      assert :ok = ExpireTickets.perform(job(%{}))
      assert :ok = ExpireTickets.perform(job(%{}))
    end
  end

  describe "отмена по недобору" do
    test "недобравший турнир отменяется, деньги возвращаются" do
      setting = setting_fixture(%{min_players: 3})
      tournament = tournament_fixture(setting)
      user = user_fixture()

      before = balance(user)
      {:ok, _entry} = Tournaments.register(tournament.id, user.id)

      assert :ok = CancelUnderfilled.perform(job(%{"tournament_id" => tournament.id}))

      {:ok, reloaded} = Tournaments.get_tournament(tournament.id)
      assert reloaded.status == :cancelled
      assert balance(user) == before
    end

    test "набравший турнир не трогается" do
      setting = setting_fixture(%{min_players: 2})
      tournament = tournament_fixture(setting)

      {:ok, _one} = Tournaments.register(tournament.id, user_fixture().id)
      {:ok, _two} = Tournaments.register(tournament.id, user_fixture().id)

      assert :ok = CancelUnderfilled.perform(job(%{"tournament_id" => tournament.id}))

      {:ok, reloaded} = Tournaments.get_tournament(tournament.id)
      assert reloaded.status == :registering
    end

    test "набор считается по людям, а не по входам" do
      # Один человек с двумя входами — это всё ещё один человек,
      # и порога в двоих он не набирает.
      setting = setting_fixture(%{min_players: 2, rebuy_allowed: true, max_rebuys: 1})
      tournament = tournament_fixture(setting)
      user = user_fixture()

      {:ok, entry} = Tournaments.register(tournament.id, user.id)
      {:ok, _busted} = Tournaments.bust(entry.id, nil)
      {:ok, _second} = Tournaments.reenter(tournament.id, user.id)

      assert :ok = CancelUnderfilled.perform(job(%{"tournament_id" => tournament.id}))

      {:ok, reloaded} = Tournaments.get_tournament(tournament.id)
      assert reloaded.status == :cancelled
    end

    test "начавшийся турнир джоба не отменяет" do
      setting = setting_fixture(%{min_players: 5})
      tournament = tournament_fixture(setting)
      {:ok, started} = Tournaments.start(tournament, nil)

      # Джоба могла проснуться после того, как оператор запустил турнир
      # руками: остановить идущий турнир она не вправе.
      assert :ok = CancelUnderfilled.perform(job(%{"tournament_id" => started.id}))

      {:ok, reloaded} = Tournaments.get_tournament(started.id)
      assert reloaded.status == :running
    end

    test "повторное выполнение не возвращает деньги дважды" do
      setting = setting_fixture(%{min_players: 3})
      tournament = tournament_fixture(setting)
      user = user_fixture()

      before = balance(user)
      {:ok, _entry} = Tournaments.register(tournament.id, user.id)

      :ok = CancelUnderfilled.perform(job(%{"tournament_id" => tournament.id}))
      :ok = CancelUnderfilled.perform(job(%{"tournament_id" => tournament.id}))

      assert balance(user) == before
    end

    test "исчезнувший турнир — не ошибка джобы" do
      assert {:error, :not_found} =
               CancelUnderfilled.perform(job(%{"tournament_id" => Ecto.UUID.generate()}))
    end
  end

  describe "дорасчёт турнира" do
    setup do
      setting = setting_fixture()
      tournament = tournament_fixture(setting)

      winner = user_fixture()
      loser = user_fixture()

      {:ok, first} = Tournaments.register(tournament.id, winner.id)
      {:ok, second} = Tournaments.register(tournament.id, loser.id)

      {:ok, tournament} = Tournaments.get_tournament(tournament.id)
      {:ok, tournament} = Tournaments.close_late_reg(tournament)

      %{tournament: tournament, winner: winner, first: first, second: second}
    end

    test "доигранный турнир рассчитывается", ctx do
      # Второй вылетел, первый остался — победитель определился.
      {:ok, _busted} = Tournaments.bust(ctx.second.id, 2)

      before = balance(ctx.winner)

      assert :ok = SettleTournament.perform(job(%{"tournament_id" => ctx.tournament.id}))

      {:ok, reloaded} = Tournaments.get_tournament(ctx.tournament.id)
      assert reloaded.status == :finished
      assert balance(ctx.winner) == before + 1300
    end

    test "недоигранный турнир не трогается", ctx do
      # Живых двое: победителя нет, и раздавать призы не за что.
      assert :ok = SettleTournament.perform(job(%{"tournament_id" => ctx.tournament.id}))

      {:ok, reloaded} = Tournaments.get_tournament(ctx.tournament.id)
      assert reloaded.status == :late_reg_closed
    end

    test "уже рассчитанный турнир не платит второй раз", ctx do
      {:ok, _busted} = Tournaments.bust(ctx.second.id, 2)

      :ok = SettleTournament.perform(job(%{"tournament_id" => ctx.tournament.id}))
      after_first = balance(ctx.winner)

      :ok = SettleTournament.perform(job(%{"tournament_id" => ctx.tournament.id}))

      assert balance(ctx.winner) == after_first
    end

    test "исчезнувший турнир — не падение" do
      assert {:error, :not_found} =
               SettleTournament.perform(job(%{"tournament_id" => Ecto.UUID.generate()}))
    end
  end
end
