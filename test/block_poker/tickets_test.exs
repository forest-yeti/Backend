defmodule BlockPoker.TicketsTest do
  @moduledoc """
  Контекст билетов на настоящей MySQL.

  Главное здесь — атомарность погашения. Билет хранится строкой на
  экземпляр, а не счётчиком в колонке, именно ради неё: счётчик
  потребовал бы атомарного декремента под конкурентной регистрацией,
  а строка со статусом даёт блокировку и историю «откуда и куда».
  """

  use BlockPoker.DataCase, async: true

  import BlockPoker.AccountsFixtures
  import BlockPoker.TournamentsFixtures

  alias BlockPoker.Tickets
  alias BlockPoker.Tickets.UserTicket

  setup do
    setting = setting_fixture()
    user = user_fixture()

    %{setting: setting, user: user, ticket: ticket_fixture(setting)}
  end

  describe "тип билета" do
    test "помнит цену на момент создания", %{setting: setting, ticket: ticket} do
      assert ticket.face_value == setting.buy_in + setting.entry_fee
    end

    test "подорожавший турнир не обесценивает выданный билет", %{
      setting: setting,
      ticket: ticket
    } do
      {:ok, _updated} =
        setting
        |> BlockPoker.Tournaments.TournamentSetting.changeset(%{buy_in: 99_999})
        |> Repo.update()

      # Номинал живёт у билета, а не выводится из шаблона: иначе оператор
      # одним UPDATE обесценил бы уже выданные призы.
      assert Repo.get!(BlockPoker.Tickets.Ticket, ticket.id).face_value == ticket.face_value
    end
  end

  describe "выдача" do
    test "билет появляется у игрока со следом происхождения", ctx do
      user_ticket = user_ticket_fixture(ctx.ticket, ctx.user, %{issued_by: "promo"})

      assert user_ticket.status == :active
      assert user_ticket.issued_by == "promo"
    end

    test "у одного игрока может быть несколько одинаковых билетов", ctx do
      _one = user_ticket_fixture(ctx.ticket, ctx.user)
      _two = user_ticket_fixture(ctx.ticket, ctx.user)

      assert length(Tickets.list_active(ctx.user.id)) == 2
    end
  end

  describe "поиск годного билета" do
    test "находит билет на нужный шаблон", ctx do
      user_ticket = user_ticket_fixture(ctx.ticket, ctx.user)

      assert {:ok, found} = Tickets.find_for(ctx.user.id, ctx.setting.id)
      assert found.id == user_ticket.id
    end

    test "билет на чужой шаблон не подходит", ctx do
      other = setting_fixture()
      _foreign = user_ticket_fixture(ticket_fixture(other), ctx.user)

      assert {:error, :not_found} = Tickets.find_for(ctx.user.id, ctx.setting.id)
    end

    test "первым отдаётся самый скорый к истечению", ctx do
      _forever = user_ticket_fixture(ctx.ticket, ctx.user)

      soon =
        user_ticket_fixture(ctx.ticket, ctx.user, %{
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      # Иначе игрок копил бы бессрочные, а срочные сгорали бы у него
      # на руках.
      assert {:ok, found} = Tickets.find_for(ctx.user.id, ctx.setting.id)
      assert found.id == soon.id
    end

    test "истёкший билет не находится", ctx do
      _expired =
        user_ticket_fixture(ctx.ticket, ctx.user, %{
          expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
        })

      assert {:error, :not_found} = Tickets.find_for(ctx.user.id, ctx.setting.id)
    end
  end

  describe "погашение" do
    test "переводит билет в used и привязывает к турниру", ctx do
      tournament = tournament_fixture(ctx.setting)
      user_ticket = user_ticket_fixture(ctx.ticket, ctx.user)

      assert {:ok, %{redeem: redeemed}} =
               Ecto.Multi.new()
               |> Tickets.redeem(:redeem, user_ticket, tournament.id)
               |> Repo.transaction()

      assert redeemed.status == :used
      assert Repo.get!(UserTicket, user_ticket.id).used_in_tournament_id == tournament.id
    end

    test "повторное погашение того же билета не проходит", ctx do
      tournament = tournament_fixture(ctx.setting)
      user_ticket = user_ticket_fixture(ctx.ticket, ctx.user)

      {:ok, _first} =
        Ecto.Multi.new()
        |> Tickets.redeem(:redeem, user_ticket, tournament.id)
        |> Repo.transaction()

      # Под блокировкой строки видно, что билет уже не активен, — это
      # и есть защита от гонки двух одновременных регистраций одним
      # билетом.
      assert {:error, :redeem, :ticket_unavailable, _changes} =
               Ecto.Multi.new()
               |> Tickets.redeem(:redeem, user_ticket, tournament.id)
               |> Repo.transaction()
    end

    test "один игрок не может погасить два билета в один турнир", ctx do
      tournament = tournament_fixture(ctx.setting)
      one = user_ticket_fixture(ctx.ticket, ctx.user)
      two = user_ticket_fixture(ctx.ticket, ctx.user)

      {:ok, _first} =
        Ecto.Multi.new() |> Tickets.redeem(:redeem, one, tournament.id) |> Repo.transaction()

      # Стережёт уникальный индекс, а не проверка в коде, — но наружу
      # он выходит доменным отказом, а не сырой ошибкой драйвера.
      assert {:error, :redeem, :already_registered, _changes} =
               Ecto.Multi.new()
               |> Tickets.redeem(:redeem, two, tournament.id)
               |> Repo.transaction()
    end
  end

  describe "возврат" do
    test "билет снова активен и снова ничей", ctx do
      tournament = tournament_fixture(ctx.setting)
      user_ticket = user_ticket_fixture(ctx.ticket, ctx.user)

      {:ok, _redeemed} =
        Ecto.Multi.new()
        |> Tickets.redeem(:redeem, user_ticket, tournament.id)
        |> Repo.transaction()

      {:ok, _refunded} =
        Ecto.Multi.new()
        |> Tickets.refund_all(:refund, tournament.id)
        |> Repo.transaction()

      returned = Repo.get!(UserTicket, user_ticket.id)

      assert returned.status == :active
      assert returned.used_in_tournament_id == nil
    end

    test "возвращённый билет пускает в следующий запуск", ctx do
      first = tournament_fixture(ctx.setting)
      user_ticket = user_ticket_fixture(ctx.ticket, ctx.user)

      {:ok, _redeemed} =
        Ecto.Multi.new() |> Tickets.redeem(:redeem, user_ticket, first.id) |> Repo.transaction()

      {:ok, _refunded} =
        Ecto.Multi.new() |> Tickets.refund_all(:refund, first.id) |> Repo.transaction()

      second = tournament_fixture(ctx.setting)

      assert {:ok, _redeemed} =
               Ecto.Multi.new()
               |> Tickets.redeem(:redeem, user_ticket, second.id)
               |> Repo.transaction()
    end
  end

  describe "истечение" do
    test "просроченные гасятся, годные не трогаются", ctx do
      _expired =
        user_ticket_fixture(ctx.ticket, ctx.user, %{
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      _alive =
        user_ticket_fixture(ctx.ticket, ctx.user, %{
          expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
        })

      _forever = user_ticket_fixture(ctx.ticket, ctx.user)

      assert {:ok, 1} = Tickets.expire_due()
      assert length(Tickets.list_active(ctx.user.id)) == 2
    end

    test "повторный прогон ничего не портит", ctx do
      _expired =
        user_ticket_fixture(ctx.ticket, ctx.user, %{
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      {:ok, 1} = Tickets.expire_due()

      assert {:ok, 0} = Tickets.expire_due()
    end
  end

  describe "выключение шаблона" do
    test "живые билеты пересчитываются", ctx do
      _one = user_ticket_fixture(ctx.ticket, ctx.user)
      _two = user_ticket_fixture(ctx.ticket, user_fixture())

      assert Tickets.count_active_for_setting(ctx.setting.id) == 2
    end

    test "предупреждение уходит в лог с числом затронутых", ctx do
      _one = user_ticket_fixture(ctx.ticket, ctx.user)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Tickets.warn_on_disable(ctx.setting.id, ctx.setting.name)
        end)

      assert log =~ "1 активных билетов"
    end

    test "без билетов молчит", ctx do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Tickets.warn_on_disable(ctx.setting.id, ctx.setting.name)
        end)

      assert log == ""
    end
  end
end
