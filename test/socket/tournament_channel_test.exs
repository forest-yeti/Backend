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

  alias BlockPoker.Engine.Rng
  alias BlockPoker.Tables.{RoomState, TableServer}
  alias BlockPoker.Tournaments
  alias BlockPoker.Tournaments.TournamentServer
  alias BlockPoker.Wallet
  alias Ecto.Adapters.SQL.Sandbox
  alias Socket.UserSocket

  defp connect_as(user) do
    {:ok, %{token: token}} = BlockPoker.Accounts.start_session(user)
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    socket
  end

  defp join_lobby(user, payload \\ %{}) do
    user |> connect_as() |> subscribe_and_join("tournaments", payload)
  end

  # Идущий турнир: стартовал в прошлом, поздняя регистрация закрыта.
  defp running_fixture(setting, starts_at) do
    tournament = tournament_fixture(setting, %{starts_at: starts_at})

    {:ok, running} =
      tournament
      |> Ecto.Changeset.change(status: :running, late_reg_until: starts_at)
      |> BlockPoker.Repo.update()

    running
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

    test "порядок: свои, потом идущие дольше всех, потом ближайшие", ctx do
      now = DateTime.utc_now()

      # Свой турнир — самый дальний по времени: он всё равно обязан быть
      # первым, потому что от игрока в нём чего-то ждут.
      mine = tournament_fixture(ctx.setting, %{starts_at: DateTime.add(now, 10_800)})
      {:ok, _entry} = Tournaments.register(mine.id, ctx.user.id)

      long = running_fixture(ctx.setting, DateTime.add(now, -7200))
      short = running_fixture(ctx.setting, DateTime.add(now, -600))
      later = tournament_fixture(ctx.setting, %{starts_at: DateTime.add(now, 7200)})

      {:ok, reply, _channel} = join_lobby(ctx.user)

      # `ctx.tournament` стартует через час — ближе, чем `later`.
      assert Enum.map(reply.tournaments, & &1.tournament_id) ==
               [mine.id, long.id, short.id, ctx.tournament.id, later.id]
    end

    test "сортировка по цене входа, времени старта и числу входов", ctx do
      now = DateTime.utc_now()

      cheap = tournament_fixture(setting_fixture(%{buy_in: 100, entry_fee: 10}))
      later = tournament_fixture(ctx.setting, %{starts_at: DateTime.add(now, 7200)})

      # Один вход в дальний турнир: по числу регистраций он обязан стать
      # первым, а по времени старта — последним.
      {:ok, _entry} = Tournaments.register(later.id, user_fixture().id)

      ids = fn reply -> Enum.map(reply.tournaments, & &1.tournament_id) end

      {:ok, reply, channel} = join_lobby(ctx.user, %{"sort" => %{"field" => "entry_price"}})
      assert ids.(reply) == [cheap.id, ctx.tournament.id, later.id]

      ref = push(channel, "list", %{"sort" => %{"field" => "starts_at", "direction" => "desc"}})
      assert_reply ref, :ok, reply
      assert hd(ids.(reply)) == later.id

      ref = push(channel, "list", %{"sort" => %{"field" => "entries", "direction" => "desc"}})
      assert_reply ref, :ok, reply
      assert hd(ids.(reply)) == later.id

      # Словарь сортировок приходит с сервера: клиент их не выдумывает.
      assert reply.filters.sort_fields == [:entry_price, :starts_at, :entries]
    end

    test "свои турниры первыми при любой сортировке", ctx do
      # Дороже и дальше остальных — то есть последний по обеим
      # выбираемым сортировкам.
      mine =
        tournament_fixture(
          setting_fixture(%{buy_in: 5000, entry_fee: 500}),
          %{starts_at: DateTime.add(DateTime.utc_now(), 10_800)}
        )

      {:ok, _entry} = Tournaments.register(mine.id, ctx.user.id)

      for sort <- [
            %{"field" => "entry_price"},
            %{"field" => "starts_at"},
            %{"field" => "entries"}
          ] do
        {:ok, reply, _channel} = join_lobby(ctx.user, %{"sort" => sort})

        assert hd(reply.tournaments).tournament_id == mine.id,
               "сортировка #{sort["field"]} увела свой турнир вниз"
      end
    end

    test "неизвестная сортировка отвергается", ctx do
      socket = connect_as(ctx.user)

      assert {:error, %{code: "validation_failed"}} =
               subscribe_and_join(socket, "tournaments", %{"sort" => %{"field" => "occupancy"}})
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

    test "чипсчёт идущего турнира несёт стек и стол", ctx do
      # Столы и турнир — отдельные процессы, и все они ходят в БД.
      Sandbox.mode(BlockPoker.Repo, {:shared, self()})
      on_exit(fn -> Sandbox.mode(BlockPoker.Repo, :manual) end)

      {:ok, _entry} = Tournaments.register(ctx.tournament.id, ctx.user.id)
      {:ok, _entry} = Tournaments.register(ctx.tournament.id, user_fixture().id)

      pid =
        start_supervised!({TournamentServer, tournament_id: ctx.tournament.id},
          id: {TournamentServer, ctx.tournament.id}
        )

      Sandbox.allow(BlockPoker.Repo, self(), pid)
      :ok = TournamentServer.start_tournament(pid)

      {:ok, _reply, channel} = join_lobby(ctx.user)

      ref = push(channel, "tournament_card", %{"tournament_id" => ctx.tournament.id})
      assert_reply ref, :ok, card

      assert [row | _rest] = card.chip_counts.entries

      # Стек живёт только в процессе турнира, а без стола клиенту нечего
      # открывать по строке чипсчёта.
      assert row.stack > 0
      assert row.table_id != nil
      assert row.user_id != nil
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

  describe "ре-энтри и аддон из канала" do
    # Ре-энтри и аддон — единственные сообщения канала, за которыми стоят
    # **и деньги, и место за столом**. Оплата без посадки (и списание без
    # фишек) выглядит для игрока как «кнопка не работает», поэтому путь
    # проверяется целиком, до стека за столом.
    defp playing_setting(overrides) do
      levels = [
        %{
          level: 1,
          small_blind: 1000,
          big_blind: 2000,
          ante: 0,
          duration_seconds: 600,
          rebuy_allowed: true,
          addon_allowed: true
        },
        %{
          level: 2,
          small_blind: 2000,
          big_blind: 4000,
          ante: 0,
          duration_seconds: 600,
          rebuy_allowed: false,
          addon_allowed: false
        }
      ]

      setting_fixture(
        Map.merge(
          %{
            table_size: 6,
            min_players: 2,
            buy_in: 1000,
            entry_fee: 100,
            starting_stack: 2000,
            addon_cost: 500,
            addon_stack: 3000
          },
          overrides
        ),
        levels
      )
    end

    defp start_playing(setting) do
      tournament = tournament_fixture(setting)
      users = for _index <- 1..2, do: user_fixture()
      for user <- users, do: {:ok, _entry} = Tournaments.register(tournament.id, user.id)

      pid =
        start_supervised!(
          {TournamentServer,
           [
             tournament_id: tournament.id,
             room_opts: [timers: :manual, rng: Rng.seeded(<<1>>)]
           ]},
          id: {TournamentServer, tournament.id}
        )

      Sandbox.allow(BlockPoker.Repo, self(), pid)
      :ok = TournamentServer.start_tournament(pid)

      [{_id, table}] = Map.to_list(:sys.get_state(pid).tables)

      %{tournament: tournament, users: users, pid: pid, table: table}
    end

    # Стек равен большому блайнду: первая раздача идёт на всё и кто-то
    # обязательно вылетает.
    defp bust_one(%{table: table, users: users, pid: pid} = ctx) do
      Enum.reduce_while(1..10, nil, fn _hand, _acc ->
        play_one_hand(table)

        # Барьер: место освобождает турнир, получив конец раздачи
        # сообщением, — до этого вылетевший ещё сидит.
        _state = TournamentServer.state(pid)

        room = TableServer.state(table)

        case Enum.find(users, &(RoomState.find_seat(room, &1.id) == nil)) do
          nil -> {:cont, nil}
          busted -> {:halt, busted}
        end
      end)
      |> case do
        nil -> flunk("никто не вылетел: #{inspect(TournamentServer.state(ctx.pid))}")
        busted -> busted
      end
    end

    defp play_one_hand(table) do
      room = TableServer.state(table)
      if room.phase == :button_draw, do: TableServer.fire_timer(table, :button_draw)
      if TableServer.state(table).hand == nil, do: TableServer.fire_timer(table, :next_hand)

      Enum.reduce_while(1..40, nil, fn _step, _acc ->
        room = TableServer.state(table)

        case room.hand do
          nil ->
            {:halt, nil}

          hand ->
            case BlockPoker.Engine.Hand.to_act(hand) do
              nil ->
                TableServer.fire_timer(table, :runout)

              number ->
                seat = Map.get(room.seats, number)
                actions = BlockPoker.Engine.Hand.legal_actions(hand, number)
                action = if actions[:call], do: :call, else: :check

                TableServer.act(table, seat.user_id, action, room.action_seq)
            end

            {:cont, nil}
        end
      end)
    end

    defp balance(user) do
      {:ok, wallet} = Wallet.get_wallet(user.id, :play_money)
      wallet.amount
    end

    test "reentry возвращает игрока за стол, а не просто берёт деньги" do
      ctx =
        start_playing(playing_setting(%{rebuy_allowed: true, rebuy_cost: 700, rebuy_stack: 3000}))

      busted = bust_one(ctx)
      assert busted

      socket = connect_as(busted)

      {:ok, _snapshot, channel} =
        subscribe_and_join(socket, "tournament:#{ctx.tournament.id}", %{})

      before = balance(busted)

      ref = push(channel, "reentry", %{})
      assert_reply ref, :ok, %{entry_number: 2}

      # Деньги ушли — и ровно на них игрок снова сидит за столом.
      assert balance(busted) == before - 700

      seat = ctx.table |> TableServer.state() |> RoomState.find_seat(busted.id)
      assert seat.stack == 3000
    end

    test "addon вне перерыва отвергается и денег не берёт" do
      ctx = start_playing(playing_setting(%{addon_cost: 500, addon_stack: 3000}))
      [user | _rest] = ctx.users

      socket = connect_as(user)

      {:ok, _snapshot, channel} =
        subscribe_and_join(socket, "tournament:#{ctx.tournament.id}", %{})

      before = balance(user)

      ref = push(channel, "addon", %{})
      assert_reply ref, :error, %{code: "addon_not_allowed"}

      assert balance(user) == before
    end

    test "addon на перерыве кладёт фишки за столом" do
      ctx = start_playing(playing_setting(%{addon_cost: 500, addon_stack: 3000}))
      [user | _rest] = ctx.users

      socket = connect_as(user)

      {:ok, _snapshot, channel} =
        subscribe_and_join(socket, "tournament:#{ctx.tournament.id}", %{})

      :ok = TournamentServer.fire(ctx.pid, :break)

      before = balance(user)
      stack_before = (ctx.table |> TableServer.state() |> RoomState.find_seat(user.id)).stack

      ref = push(channel, "addon", %{})
      assert_reply ref, :ok, %{stack: stack}

      assert balance(user) == before - 500
      assert stack == stack_before + 3000

      seat = ctx.table |> TableServer.state() |> RoomState.find_seat(user.id)
      assert seat.stack == stack
    end
  end
end
