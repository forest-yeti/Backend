defmodule Socket.Channels.TournamentChannelTest do
  @moduledoc """
  Турнирный канал насквозь: витрина, карточка, регистрация и события
  инстанса.

  Путь целиком — клиент шлёт сообщение, ядро отрабатывает, клиент
  получает ответ или push. Здесь же проверяется то, ради чего канал и
  существует отдельно от лобби: персональные фильтры считаются от
  `user_id` сокета, а не из payload.
  """

  use Socket.ChannelCase, async: false

  import BlockPoker.AccountsFixtures
  import BlockPoker.TournamentsFixtures

  alias BlockPoker.Tournaments
  alias Socket.UserSocket

  defp connect_as(user) do
    {:ok, %{token: token}} = BlockPoker.Accounts.start_session(user)
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    socket
  end

  defp join_lobby(user, payload \\ %{}) do
    user |> connect_as() |> subscribe_and_join("tournaments", payload)
  end

  setup do
    setting = setting_fixture(%{table_size: 6, min_players: 2})

    %{setting: setting, tournament: tournament_fixture(setting), user: user_fixture()}
  end

  describe "витрина" do
    test "отдаёт строки инстансов и словарь фильтров", ctx do
      {:ok, reply, _channel} = join_lobby(ctx.user)

      assert [row] = reply.tournaments
      assert row.tournament_id == ctx.tournament.id
      assert row.status == :registering

      # Фильтры приходят с сервера: новый вид покера не должен требовать
      # релиза клиента.
      assert :texas_holdem in reply.filters.game_types
      assert :late_reg in reply.filters.statuses
      assert :satellite in reply.filters.kinds
    end

    test "цена входа отдаётся одним числом", ctx do
      {:ok, reply, _channel} = join_lobby(ctx.user)

      [row] = reply.tournaments

      assert row.buy_in == 1000
      assert row.entry_fee == 100

      # То, что спишется, — и есть то, что клиент показывает игроку.
      assert row.entry_price == 1100
    end

    test "фильтр по статусу отсеивает лишнее", ctx do
      {:ok, reply, _channel} = join_lobby(ctx.user, %{"statuses" => ["running"]})

      assert reply.tournaments == []
    end

    test "неизвестное значение фильтра — ошибка, а не пустая витрина", ctx do
      socket = connect_as(ctx.user)

      assert {:error, %{code: "validation_failed"}} =
               subscribe_and_join(socket, "tournaments", %{"statuses" => ["нет такого"]})
    end

    test "фильтр «мои» считается от сокета, а не из payload", ctx do
      stranger = user_fixture()
      {:ok, _entry} = Tournaments.register(ctx.tournament.id, stranger.id)

      # Игрок не зарегистрирован — его витрина «моих» пуста, хотя турнир
      # существует и в нём кто-то есть.
      {:ok, reply, _channel} = join_lobby(ctx.user, %{"mine" => true})
      assert reply.tournaments == []

      {:ok, reply, _channel} = join_lobby(stranger, %{"mine" => true})
      assert [_row] = reply.tournaments
    end

    test "фильтр «есть билет» тоже персональный", ctx do
      ticket = ticket_fixture(ctx.setting)
      holder = user_fixture()
      _user_ticket = user_ticket_fixture(ticket, holder)

      {:ok, reply, _channel} = join_lobby(ctx.user, %{"has_ticket" => true})
      assert reply.tournaments == []

      {:ok, reply, _channel} = join_lobby(holder, %{"has_ticket" => true})
      assert [row] = reply.tournaments
      assert row.has_ticket
    end

    test "порядок задаёт сервер: ближайший старт первым", ctx do
      later =
        tournament_fixture(ctx.setting, %{starts_at: DateTime.add(DateTime.utc_now(), 7200)})

      _sooner = ctx.tournament

      {:ok, reply, _channel} = join_lobby(ctx.user)

      assert Enum.map(reply.tournaments, & &1.tournament_id) == [ctx.tournament.id, later.id]
    end

    test "перечитывает витрину на изменение инстанса", ctx do
      {:ok, _reply, _channel} = join_lobby(ctx.user)

      {:ok, _entry} = Tournaments.register(ctx.tournament.id, ctx.user.id)

      assert_push "lobby_delta", %{tournaments: [row]}
      assert row.entries_count == 1
      assert row.registered
    end
  end

  describe "карточка" do
    test "отдаёт структуру, сетку и чипсчёт", ctx do
      {:ok, _entry} = Tournaments.register(ctx.tournament.id, ctx.user.id)
      {:ok, _reply, channel} = join_lobby(ctx.user)

      ref = push(channel, "tournament_card", %{"tournament_id" => ctx.tournament.id})
      assert_reply ref, :ok, card

      assert length(card.blind_levels) == 2
      assert hd(card.blind_levels).label == "25/50"

      # Флаги входа приходят вместе с уровнем: клиент рисует по ним,
      # до какого уровня открыта поздняя регистрация.
      assert hd(card.blind_levels).rebuy_allowed

      assert card.chip_counts.total == 1
      assert card.chip_counts.limit == 50
    end

    test "сетка выплат считается при текущей явке", ctx do
      for _index <- 1..2 do
        {:ok, _entry} = Tournaments.register(ctx.tournament.id, user_fixture().id)
      end

      {:ok, tournament} = Tournaments.get_tournament(ctx.tournament.id)
      {:ok, _closed} = Tournaments.close_late_reg(tournament)

      {:ok, _reply, channel} = join_lobby(ctx.user)

      ref = push(channel, "tournament_card", %{"tournament_id" => ctx.tournament.id})
      assert_reply ref, :ok, card

      assert Enum.map(card.payouts, & &1.place) == [1, 2]
      assert Enum.sum(Enum.map(card.payouts, & &1.amount)) == 2000
    end

    test "карточка пустого турнира не роняет канал", ctx do
      {:ok, _reply, channel} = join_lobby(ctx.user)

      ref = push(channel, "tournament_card", %{"tournament_id" => ctx.tournament.id})
      assert_reply ref, :ok, card

      assert card.payouts == []
      assert card.chip_counts.entries == []
    end

    test "несуществующий турнир — ошибка, а не падение", ctx do
      {:ok, _reply, channel} = join_lobby(ctx.user)

      ref = push(channel, "tournament_card", %{"tournament_id" => Ecto.UUID.generate()})
      assert_reply ref, :error, %{code: "not_found"}
    end
  end

  describe "регистрация" do
    test "списывает деньги и отдаёт номер входа", ctx do
      {:ok, _reply, channel} = join_lobby(ctx.user)

      ref = push(channel, "register", %{"tournament_id" => ctx.tournament.id})
      assert_reply ref, :ok, %{entry_number: 1}

      assert Tournaments.registered?(ctx.tournament.id, ctx.user.id)
    end

    test "повторная регистрация отвергается кодом", ctx do
      {:ok, _reply, channel} = join_lobby(ctx.user)

      ref = push(channel, "register", %{"tournament_id" => ctx.tournament.id})
      assert_reply ref, :ok, _entry

      ref = push(channel, "register", %{"tournament_id" => ctx.tournament.id})
      assert_reply ref, :error, %{code: "already_registered"}
    end

    test "нехватка денег приходит понятным кодом" do
      setting = setting_fixture(%{buy_in: 100_000})
      tournament = tournament_fixture(setting)
      user = user_fixture()

      {:ok, _reply, channel} = join_lobby(user)

      ref = push(channel, "register", %{"tournament_id" => tournament.id})
      assert_reply ref, :error, %{code: "insufficient_funds"}
    end

    test "регистрация билетом гасит билет, а не деньги", ctx do
      ticket = ticket_fixture(ctx.setting)
      _user_ticket = user_ticket_fixture(ticket, ctx.user)

      {:ok, _reply, channel} = join_lobby(ctx.user)

      ref =
        push(channel, "register", %{
          "tournament_id" => ctx.tournament.id,
          "pay_with" => "ticket"
        })

      assert_reply ref, :ok, _entry
      assert BlockPoker.Tickets.list_active(ctx.user.id) == []
    end

    test "без билета отказ приходит кодом", ctx do
      {:ok, _reply, channel} = join_lobby(ctx.user)

      ref =
        push(channel, "register", %{
          "tournament_id" => ctx.tournament.id,
          "pay_with" => "ticket"
        })

      assert_reply ref, :error, %{code: "ticket_required"}
    end

    test "разрегистрация возвращает деньги", ctx do
      {:ok, _reply, channel} = join_lobby(ctx.user)

      ref = push(channel, "register", %{"tournament_id" => ctx.tournament.id})
      assert_reply ref, :ok, _entry

      ref = push(channel, "unregister", %{"tournament_id" => ctx.tournament.id})
      assert_reply ref, :ok, _reply

      refute Tournaments.registered?(ctx.tournament.id, ctx.user.id)
    end

    test "битый payload не роняет канал", ctx do
      {:ok, _reply, channel} = join_lobby(ctx.user)

      ref = push(channel, "register", %{"tournament_id" => 42})
      assert_reply ref, :error, %{code: "validation_failed"}

      assert Process.alive?(channel.channel_pid)
    end
  end

  describe "топик инстанса" do
    test "отдаёт снапшот при join", ctx do
      socket = connect_as(ctx.user)

      assert {:ok, snapshot, _channel} =
               subscribe_and_join(socket, "tournament:#{ctx.tournament.id}", %{})

      assert snapshot.tournament_id == ctx.tournament.id
    end

    test "несуществующий инстанс не пускает", ctx do
      socket = connect_as(ctx.user)

      assert {:error, %{code: "not_found"}} =
               subscribe_and_join(socket, "tournament:#{Ecto.UUID.generate()}", %{})
    end

    test "ping отвечает без похода в ядро", ctx do
      socket = connect_as(ctx.user)

      {:ok, _snapshot, channel} =
        subscribe_and_join(socket, "tournament:#{ctx.tournament.id}", %{})

      ref = push(channel, "ping", %{"t" => 123})
      assert_reply ref, :ok, %{client_time: 123, server_time: _server}
    end
  end
end
