defmodule BlockPoker.Tournaments.TournamentFlowTest do
  @moduledoc """
  Турнир целиком: расписание → анонс → регистрация → старт → игра →
  вылет → выплата.

  Единственный тест, который проверяет, что все части сходятся. Раздачи
  здесь настоящие: игроки ходят через `TableServer`, вылет считает
  движок, место присваивает турнир, деньги пишет контекст. Ни одна
  часть не подменена, потому что подменённая часть — это то место, где
  ошибка и спрячется.

  Инварианты, ради которых он существует:

    * фишки турнира не появляются и не исчезают;
    * сумма выплат ровно равна фонду;
    * места идут подряд и достаются тем, кто вылетел.
  """

  use BlockPoker.DataCase, async: false

  import BlockPoker.AccountsFixtures
  import BlockPoker.TournamentsFixtures

  alias BlockPoker.Engine.Rng
  alias BlockPoker.Engine.Rng
  alias BlockPoker.Tables.{RoomState, TableServer}
  alias BlockPoker.Tournaments
  alias BlockPoker.Tournaments.{Entry, TournamentServer}
  alias BlockPoker.Wallet
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(BlockPoker.Repo, {:shared, self()})
    on_exit(fn -> Sandbox.mode(BlockPoker.Repo, :manual) end)

    # Блайнды сопоставимы со стеком: иначе двое доигрывали бы турнир
    # сотнями раздач, и тест мерил бы терпение, а не правила.
    %{setting: fast_setting()}
  end

  # Шаблон, где турнир заканчивается за считаные раздачи: большой блайнд
  # почти равен стеку, и первая же раздача идёт на всё.
  defp fast_setting(overrides \\ %{}) do
    levels = [
      %{
        level: 1,
        small_blind: 1000,
        big_blind: 2000,
        ante: 0,
        duration_seconds: 600,
        rebuy_allowed: true,
        addon_allowed: false
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
        %{table_size: 6, min_players: 2, buy_in: 1000, entry_fee: 100, starting_stack: 5000},
        overrides
      ),
      levels
    )
  end

  defp balance(user) do
    {:ok, wallet} = Wallet.get_wallet(user.id, :play_money)
    wallet.amount
  end

  defp start_server(tournament_id, opts \\ []) do
    # Столы с ручными таймерами: пауза между раздачами в тестах не
    # отсчитывается реальным временем (§11 CLAUDE.md).
    args =
      Keyword.merge([tournament_id: tournament_id, room_opts: [timers: :manual]], opts)

    pid = start_supervised!({TournamentServer, args}, id: {TournamentServer, tournament_id})

    Sandbox.allow(BlockPoker.Repo, self(), pid)
    pid
  end

  # Доводит стол до раздачи: розыгрыш кнопки и пауза между раздачами
  # прогоняются вручную, а не ожиданием.
  defp deal_hand(table) do
    room = TableServer.state(table)

    if room.phase == :button_draw, do: TableServer.fire_timer(table, :button_draw)

    if TableServer.state(table).hand == nil, do: TableServer.fire_timer(table, :next_hand)
  end

  # Играет, пока кто-то не вылетит: нужен тестам ре-энтри, где важен
  # именно момент вылета, а не конец турнира.
  defp play_until_bust(pid, table, limit \\ 30) do
    Enum.reduce_while(1..limit, :playing, fn _index, _acc ->
      if TournamentServer.state(pid).players_left < 2 do
        {:halt, :busted}
      else
        deal_hand(table)
        play_hand(table)
        {:cont, :playing}
      end
    end)
  end

  # То же, но турнир идёт на нескольких столах: состав столов меняется
  # балансировкой, поэтому список читается заново на каждом круге.
  defp play_tables_until_finished(pid) do
    Enum.reduce_while(1..80, :playing, fn _index, _acc ->
      if TournamentServer.state(pid).status == :finished do
        {:halt, :finished}
      else
        for {_id, table} <- :sys.get_state(pid).tables do
          deal_hand(table)
          play_hand(table)
        end

        {:cont, :playing}
      end
    end)
  end

  # Играет раздачи, пока турнир не кончится. Пауза между раздачами
  # прогоняется вручную, а не ожиданием.
  defp play_until_finished(pid, table, limit \\ 60) do
    Enum.reduce_while(1..limit, :playing, fn _index, _acc ->
      if TournamentServer.state(pid).status == :finished do
        {:halt, :finished}
      else
        deal_hand(table)
        play_hand(table)
        {:cont, :playing}
      end
    end)
  end

  # Доигрывает раздачу до конца: все ходят чек/фолд, пока раздача идёт.
  # Кто именно выиграет — тесту неважно, важно, что раздача завершится
  # и турнир получит `hand_finished`.
  defp play_hand(table) do
    Enum.reduce_while(1..40, :playing, fn _step, _acc ->
      room = TableServer.state(table)

      case room.hand do
        nil ->
          {:halt, :finished}

        hand ->
          act_or_run_out(table, room, hand)
          {:cont, :playing}
      end
    end)
  end

  # Ходить некому — значит раздача ушла в доводку после олл-ина: карты
  # доборного борта открываются по таймеру, и под ручными таймерами его
  # прогоняет тест. Без этого раздача с олл-ином зависает навсегда.
  defp act_or_run_out(table, room, hand) do
    case BlockPoker.Engine.Hand.to_act(hand) do
      nil ->
        TableServer.fire_timer(table, :runout)

      seat_number ->
        seat = Map.get(room.seats, seat_number)

        if seat && seat.user_id do
          TableServer.act(table, seat.user_id, action_for(hand, seat_number), room.action_seq)
        end
    end
  end

  # Чек, если можно, иначе колл: так раздача доходит до вскрытия, и на
  # блайндах, сопоставимых со стеком, кто-то обязательно вылетает.
  # Ключи набора легальных действий несут значения, а не признаки:
  # `check: false` означает «нельзя», а не «нет ключа».
  defp action_for(hand, seat_number) do
    actions = BlockPoker.Engine.Hand.legal_actions(hand, seat_number)

    cond do
      actions[:check] -> :check
      actions[:call] -> :call
      true -> :fold
    end
  end

  # Доигрывает **ровно текущую** раздачу. Обычный `play_hand/1` играет,
  # пока за столом идёт раздача, — а на снятии паузы стол начинает
  # следующую сразу, и тест сыграл бы лишний круг там, где проверяет
  # именно один.
  defp play_current_hand(table) do
    before = TableServer.state(table).hands_played

    Enum.reduce_while(1..40, :playing, fn _step, _acc ->
      room = TableServer.state(table)

      cond do
        room.hands_played > before -> {:halt, :finished}
        room.hand == nil -> {:halt, :finished}
        true -> act_or_run_out(table, room, room.hand) && {:cont, :playing}
      end
    end)
  end

  # Барьер: конец раздачи доезжает до турнира сообщением, и решения
  # (пауза стола, снятие паузы, пересадка) турнир принимает уже после
  # того, как тест увидел раздачу законченной. Синхронный вызов
  # гарантирует, что это уже случилось.
  defp sync_tournament(pid) do
    _state = TournamentServer.state(pid)
    :ok
  end

  # Играет раздачи на одном столе, пока условие не выполнится.
  defp play_hands_until(pid, table, done?, limit \\ 30) do
    Enum.reduce_while(1..limit, :playing, fn _index, _acc ->
      state = TournamentServer.state(pid)

      if state.status == :finished or done?.(state) do
        {:halt, :done}
      else
        deal_hand(table)
        play_hand(table)
        {:cont, :playing}
      end
    end)
  end

  # Играет по кругу, пока условие не выполнится. Состав столов меняется
  # балансировкой, поэтому список читается заново на каждом круге.
  defp play_tables_until(pid, done?, limit \\ 80) do
    Enum.reduce_while(1..limit, :playing, fn _index, _acc ->
      state = TournamentServer.state(pid)

      if state.status == :finished or done?.(state) do
        {:halt, :done}
      else
        for {_id, table} <- :sys.get_state(pid).tables do
          deal_hand(table)
          play_hand(table)
        end

        {:cont, :playing}
      end
    end)
  end

  # Всё, что накопилось в почтовом ящике от турнира. Нужен там, где
  # проверяется отсутствие повторов, а не факт события.
  defp receive_all(acc \\ []) do
    receive do
      {:tournament_event, event, payload} -> receive_all([{event, payload} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp chips_at(table) do
    room = TableServer.state(table)

    pot = if room.hand, do: room.hand.pot, else: 0

    Enum.reduce(RoomState.seats(room), pot, fn seat, acc -> acc + seat.stack end)
  end

  describe "турнир на двоих от старта до выплаты" do
    setup ctx do
      tournament = tournament_fixture(ctx.setting)

      one = user_fixture()
      two = user_fixture()

      {:ok, _first} = Tournaments.register(tournament.id, one.id)
      {:ok, _second} = Tournaments.register(tournament.id, two.id)

      pid = start_server(tournament.id)
      :ok = TournamentServer.start_tournament(pid)

      [{table_id, table}] = Map.to_list(:sys.get_state(pid).tables)

      %{tournament: tournament, users: [one, two], pid: pid, table: table, table_id: table_id}
    end

    test "стол поднят и оба игрока за ним", ctx do
      room = TableServer.state(ctx.table)

      assert RoomState.seats_taken(room) == 2

      # Стек назначил турнир, а не стол: фишки приходят из снапшота.
      assert Enum.all?(RoomState.players(room), &(&1.stack == 5000))
    end

    test "фишки турнира не появляются и не исчезают", ctx do
      before = chips_at(ctx.table)

      deal_hand(ctx.table)
      play_hand(ctx.table)

      assert chips_at(ctx.table) == before
      assert before == 2 * 5000
    end

    test "финальный стол узнаёт об итоге в своём канале, а не только в турнирном", ctx do
      # Победитель сидит в топике стола (`table:<id>`), а не турнира: без
      # отдельного броадкаста туда его канал не узнал бы, что игра
      # кончилась, и молча ждал бы дальше — `TableSupervisor.stop_room/1`
      # его процесс не мониторит.
      Phoenix.PubSub.subscribe(BlockPoker.PubSub, TableServer.topic(ctx.table_id))

      assert play_until_finished(ctx.pid, ctx.table) == :finished

      assert_received {:table_event, "tournament_finished", payload}
      assert payload.room_id == ctx.table_id
      assert length(payload.results) == 2

      # Стол не пропадает в ту же секунду — победитель успевает увидеть
      # итог, прежде чем комнату остановят.
      assert Process.alive?(ctx.table)
    end

    test "турнир доигрывается до победителя и платит", ctx do
      [one, two] = ctx.users
      before_one = balance(one)
      before_two = balance(two)

      assert play_until_finished(ctx.pid, ctx.table) == :finished

      {:ok, reloaded} = Tournaments.get_tournament(ctx.tournament.id)
      assert reloaded.status == :finished

      # Фонд собран с двух взносов по 1000; комиссия осталась руму.
      assert reloaded.prize_pool == 2000

      # Сумма выплат ровно равна фонду: один взял 1300, второй 700.
      paid = balance(one) - before_one + (balance(two) - before_two)
      assert paid == 2000
    end

    test "места распределены и достались обоим", ctx do
      :finished = play_until_finished(ctx.pid, ctx.table)

      entries = Tournaments.list_entries(ctx.tournament.id)
      places = entries |> Enum.map(& &1.place) |> Enum.sort()

      assert places == [1, 2]
      assert Enum.all?(entries, &(&1.status == :paid))
    end

    test "выбывший помечен, победитель — нет", ctx do
      :finished = play_until_finished(ctx.pid, ctx.table)

      entries = Tournaments.list_entries(ctx.tournament.id)

      winner = Enum.find(entries, &(&1.place == 1))
      loser = Enum.find(entries, &(&1.place == 2))

      assert winner.prize == 1300
      assert loser.prize == 700
      assert loser.busted_at
      refute winner.busted_at
    end

    test "player_busted несёт приз за место — экран вылета (задача 32) не ждёт расчёта турнира",
         ctx do
      # Итоговый `entry.prize` пишется только при расчёте всего турнира
      # (`play_until_finished` ждёт именно этого), а вылетевший видит
      # экран сразу по броадкасту. У двоих игроков с этим шаблоном
      # больше некому войти — сетка «при текущей явке» на месте вылета
      # уже совпадает с окончательной.
      Phoenix.PubSub.subscribe(BlockPoker.PubSub, Tournaments.topic(ctx.tournament.id))

      :finished = play_until_finished(ctx.pid, ctx.table)

      assert_received {:tournament_event, "player_busted", busted}
      assert busted.place == 2
      assert busted.prize == 700
      assert busted.bounty_earned == 0
    end
  end

  describe "баунти" do
    test "голова выбитого достаётся победителю банка", ctx do
      setting = fast_setting(%{bounty_part: 400})
      tournament = tournament_fixture(setting)

      one = user_fixture()
      two = user_fixture()

      {:ok, _first} = Tournaments.register(tournament.id, one.id)
      {:ok, _second} = Tournaments.register(tournament.id, two.id)

      pid = start_server(tournament.id)
      :ok = TournamentServer.start_tournament(pid)

      [{_id, table}] = Map.to_list(:sys.get_state(pid).tables)

      before = balance(one) + balance(two)

      :finished = play_until_finished(pid, table)

      # Собрано: 2 × (1000 − 400) = 1200 в фонд, 2 × 400 = 800 в головы.
      # Обе головы возвращаются игрокам: одна убийце, одна победителю.
      assert balance(one) + balance(two) - before == 2000

      entries = Tournaments.list_entries(tournament.id)
      assert Enum.all?(entries, &(&1.status == :paid))
    end

    test "player_busted несёт и приз, и заработанное баунти", _ctx do
      setting = fast_setting(%{bounty_part: 400})
      tournament = tournament_fixture(setting)

      one = user_fixture()
      two = user_fixture()

      {:ok, _first} = Tournaments.register(tournament.id, one.id)
      {:ok, _second} = Tournaments.register(tournament.id, two.id)

      pid = start_server(tournament.id)
      :ok = TournamentServer.start_tournament(pid)

      [{_id, table}] = Map.to_list(:sys.get_state(pid).tables)

      Phoenix.PubSub.subscribe(BlockPoker.PubSub, Tournaments.topic(tournament.id))

      :finished = play_until_finished(pid, table)

      assert_received {:tournament_event, "player_busted", busted}

      entries = Tournaments.list_entries(tournament.id)
      loser = Enum.find(entries, &(&1.place == 2))

      # Явка не растёт дальше — сетка «при текущей явке» на момент вылета
      # совпадает с окончательным призом.
      assert busted.prize == loser.prize

      # Проигравший никого не убивал: голова досталась победителю, а тот
      # ещё не вылетел и `player_busted` про себя не получал.
      assert busted.bounty_earned == 0
    end
  end

  describe "ре-энтри" do
    setup do
      setting = fast_setting(%{rebuy_allowed: true, max_rebuys: 1})
      tournament = tournament_fixture(setting)

      one = user_fixture()
      two = user_fixture()

      {:ok, _first} = Tournaments.register(tournament.id, one.id)
      {:ok, _second} = Tournaments.register(tournament.id, two.id)

      pid = start_server(tournament.id)
      :ok = TournamentServer.start_tournament(pid)

      [{_id, table}] = Map.to_list(:sys.get_state(pid).tables)

      Phoenix.PubSub.subscribe(BlockPoker.PubSub, Tournaments.topic(tournament.id))

      %{tournament: tournament, users: [one, two], pid: pid, table: table}
    end

    test "вылет на ребайном уровне предлагает войти заново, а не присваивает место", ctx do
      play_until_bust(ctx.pid, ctx.table)

      assert_received {:tournament_event, "reentry_offer", offer}

      assert offer.cost == 1100
      assert offer.stack == 5000
      assert offer.left == 1

      # Место ещё не присвоено: вылет не окончателен, пока идёт окно.
      entry = Repo.get!(Entry, offer.entry_id)
      assert entry.place == nil
      assert entry.status == :busted
    end

    test "вход заново сажает игрока обратно и не присваивает места", ctx do
      play_until_bust(ctx.pid, ctx.table)

      assert_received {:tournament_event, "reentry_offer", offer}

      assert {:ok, entry} = TournamentServer.reenter(ctx.pid, offer.user_id)
      assert entry.entry_number == 2

      # Живых снова двое, мест не присвоено никому.
      assert TournamentServer.state(ctx.pid).players_left == 2
      assert Repo.get!(Entry, offer.entry_id).place == nil
    end

    test "вошедший заново сидит за столом и играет", ctx do
      play_until_bust(ctx.pid, ctx.table)

      assert_received {:tournament_event, "reentry_offer", offer}
      assert {:ok, _entry} = TournamentServer.reenter(ctx.pid, offer.user_id)

      room = TableServer.state(ctx.table)
      seat = RoomState.find_seat(room, offer.user_id)

      assert seat != nil
      assert seat.stack == 5000
      refute seat.waiting_for_bb

      # Игроков снова двое — стол разыгрывает кнопку и сдаёт: вошедший
      # заново играет, а не сидит перед пустым столом.
      deal_hand(ctx.table)

      assert TableServer.state(ctx.table).hand != nil
    end

    test "вошедший заново не двоится в чипсчёте", ctx do
      play_until_bust(ctx.pid, ctx.table)

      assert_received {:tournament_event, "reentry_offer", offer}
      assert {:ok, _entry} = TournamentServer.reenter(ctx.pid, offer.user_id)

      {:ok, card} = Tournaments.card(ctx.tournament.id)
      rows = card.chip_counts.entries

      # Отменённый ре-энтри вход из списка ушёл: игрок один, со стеком.
      assert card.chip_counts.total == 2
      assert length(rows) == 2

      assert [row] = Enum.filter(rows, &(&1.user_id == offer.user_id))
      assert row.entry_number == 2
      assert row.stack == 5000
    end

    test "истёкшее окно присваивает место", ctx do
      play_until_bust(ctx.pid, ctx.table)

      assert_received {:tournament_event, "reentry_offer", offer}

      send(ctx.pid, {:reentry_expired, offer.entry_id})
      _sync = TournamentServer.state(ctx.pid)

      entry = Repo.get!(Entry, offer.entry_id)
      assert entry.place == 2
      assert entry.status in [:busted, :paid]
    end

    test "исчерпанный лимит вылетает сразу, без предложения" do
      setting = fast_setting(%{rebuy_allowed: true, max_rebuys: 0})
      tournament = tournament_fixture(setting)

      for _index <- 1..2 do
        {:ok, _entry} = Tournaments.register(tournament.id, user_fixture().id)
      end

      pid = start_server(tournament.id)
      :ok = TournamentServer.start_tournament(pid)
      [{_id, table}] = Map.to_list(:sys.get_state(pid).tables)

      Phoenix.PubSub.subscribe(BlockPoker.PubSub, Tournaments.topic(tournament.id))

      :finished = play_until_finished(pid, table)

      refute_received {:tournament_event, "reentry_offer", _offer}
      assert_received {:tournament_event, "player_busted", _busted}
    end

    test "поздняя регистрация закрыта по часам — ре-энтри не предлагается, даже если уровень ещё разрешает" do
      # Уровень остаётся первым (ребайным) весь тест: `rebuy_allowed`
      # там `true`. Часы турнира при этом уводим за `late_reg_until` —
      # ровно так выглядит стол после перерыва, где счётчик уровня стоял,
      # а стенные часы продолжали идти (см. `TournamentBreak`).
      setting = fast_setting(%{rebuy_allowed: true, max_rebuys: 1})
      tournament = tournament_fixture(setting)

      one = user_fixture()
      two = user_fixture()

      {:ok, _first} = Tournaments.register(tournament.id, one.id)
      {:ok, _second} = Tournaments.register(tournament.id, two.id)

      {:ok, clock} = Agent.start_link(fn -> DateTime.utc_now() end)
      wall = fn -> Agent.get(clock, & &1) end

      pid = start_server(tournament.id, wall: wall)
      :ok = TournamentServer.start_tournament(pid)
      [{_id, table}] = Map.to_list(:sys.get_state(pid).tables)

      Phoenix.PubSub.subscribe(BlockPoker.PubSub, Tournaments.topic(tournament.id))

      # Уровень 1 длится 600 секунд — уводим часы на 601-ю.
      Agent.update(clock, &DateTime.add(&1, 601, :second))

      play_until_bust(pid, table)

      refute_received {:tournament_event, "reentry_offer", _offer}
      assert_received {:tournament_event, "player_busted", _busted}
    end
  end

  describe "аддон" do
    setup do
      # Аддон разрешён на первом уровне, и он же ребайный.
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

      setting =
        setting_fixture(
          %{
            table_size: 6,
            min_players: 2,
            starting_stack: 5000,
            addon_cost: 500,
            addon_stack: 3000
          },
          levels
        )

      tournament = tournament_fixture(setting)

      one = user_fixture()
      {:ok, _first} = Tournaments.register(tournament.id, one.id)
      {:ok, _second} = Tournaments.register(tournament.id, user_fixture().id)

      pid = start_server(tournament.id)
      :ok = TournamentServer.start_tournament(pid)

      [{_id, table}] = Map.to_list(:sys.get_state(pid).tables)

      %{tournament: tournament, user: one, pid: pid, table: table}
    end

    test "вне перерыва аддон недоступен", ctx do
      assert {:error, :addon_not_allowed} = TournamentServer.addon(ctx.pid, ctx.user.id)
    end

    test "на перерыве аддон кладёт фишки за столом", ctx do
      :ok = TournamentServer.fire(ctx.pid, :break)

      assert {:ok, %{stack: stack}} = TournamentServer.addon(ctx.pid, ctx.user.id)

      # Стартовые пять тысяч плюс три тысячи аддона — минус блайнды,
      # если они успели уйти.
      assert stack >= 5000

      seat = ctx.table |> TableServer.state() |> RoomState.find_seat(ctx.user.id)
      assert seat.stack == stack
    end

    test "аддон идёт в фонд и списывает деньги", ctx do
      before = balance(ctx.user)

      :ok = TournamentServer.fire(ctx.pid, :break)
      {:ok, _result} = TournamentServer.addon(ctx.pid, ctx.user.id)

      assert balance(ctx.user) == before - 500

      {:ok, reloaded} = Tournaments.get_tournament(ctx.tournament.id)
      assert reloaded.addons_count == 1
    end

    test "на финальном столе аддона нет ни на каком уровне", ctx do
      Phoenix.PubSub.subscribe(BlockPoker.PubSub, Tournaments.topic(ctx.tournament.id))

      [{table_id, _pid}] = Map.to_list(:sys.get_state(ctx.pid).tables)
      :sys.replace_state(ctx.pid, &%{&1 | final_table: table_id})

      :ok = TournamentServer.fire(ctx.pid, :break)

      # Все оставшиеся уже в деньгах: докупка меняла бы расклад сил
      # после пузыря, поэтому окна нет и запрос отвергается.
      refute_received {:tournament_event, "addon_offer", _offer}
      assert {:error, :addon_not_allowed} = TournamentServer.addon(ctx.pid, ctx.user.id)
    end

    test "перерыв объявляет окно аддона", ctx do
      Phoenix.PubSub.subscribe(BlockPoker.PubSub, Tournaments.topic(ctx.tournament.id))

      :ok = TournamentServer.fire(ctx.pid, :break)

      assert_received {:tournament_event, "addon_offer", offer}
      assert offer.cost == 500
      assert offer.stack == 3000
      assert offer.deadline_ms == 300_000
    end
  end

  describe "поздняя регистрация" do
    test "вошедший после старта садится за стол", ctx do
      tournament = tournament_fixture(ctx.setting)

      for _index <- 1..2 do
        {:ok, _entry} = Tournaments.register(tournament.id, user_fixture().id)
      end

      pid = start_server(tournament.id)
      :ok = TournamentServer.start_tournament(pid)

      latecomer = user_fixture()
      {:ok, entry} = Tournaments.register(tournament.id, latecomer.id)

      # Сажает сама регистрация: отдельного вызова со стороны клиента нет.
      assert {:error, :already_seated} = TournamentServer.seat_entry(pid, entry)

      assert TournamentServer.state(pid).players_left == 3

      # Стартовый стек независимо от того, сколько уровней прошло: это
      # стандарт, и он же объясняет, почему поздняя рега закрывается.
      [{_id, table}] = Map.to_list(:sys.get_state(pid).tables)
      seat = table |> TableServer.state() |> RoomState.find_seat(latecomer.id)

      assert seat.stack == 5000
    end

    test "вошедший после старта играет ближайшую раздачу, а не ждёт блайнда", ctx do
      tournament = tournament_fixture(ctx.setting)

      for _index <- 1..3 do
        {:ok, _entry} = Tournaments.register(tournament.id, user_fixture().id)
      end

      pid = start_server(tournament.id)
      :ok = TournamentServer.start_tournament(pid)

      latecomer = user_fixture()
      {:ok, _entry} = Tournaments.register(tournament.id, latecomer.id)

      [{_id, table}] = Map.to_list(:sys.get_state(pid).tables)
      seat = table |> TableServer.state() |> RoomState.find_seat(latecomer.id)

      refute seat.waiting_for_bb
      refute seat.post_required
    end
  end

  describe "нечётная явка на 2-Max" do
    test "двое играют, третий ждёт", _ctx do
      setting = fast_setting(%{table_size: 2, min_players: 2})
      tournament = tournament_fixture(setting)

      for _index <- 1..3,
          do: {:ok, _entry} = Tournaments.register(tournament.id, user_fixture().id)

      # Карты фиксированы: вылет на перерыве — условие сценария, а не удача.
      pid = start_server(tournament.id, room_opts: [timers: :manual, rng: Rng.seeded(<<1>>)])
      :ok = TournamentServer.start_tournament(pid)

      tables = Map.values(:sys.get_state(pid).tables)
      for table <- tables, do: deal_hand(table)

      rooms = Enum.map(tables, &TableServer.state/1)

      # Пара играет, третий сидит один и ждёт: сажать его не с кем, но
      # и держать из-за него остальных турнир не имеет права.
      assert Enum.count(rooms, &(&1.hand != nil)) == 1
      assert Enum.map(rooms, &length(RoomState.players(&1))) |> Enum.sort() == [1, 2]
    end

    test "с одним раздающим столом hand-for-hand не включается", _ctx do
      setting = fast_setting(%{table_size: 2, min_players: 2})
      tournament = tournament_fixture(setting)

      for _index <- 1..3,
          do: {:ok, _entry} = Tournaments.register(tournament.id, user_fixture().id)

      pid = start_server(tournament.id)
      :ok = TournamentServer.start_tournament(pid)

      Phoenix.PubSub.subscribe(BlockPoker.PubSub, Tournaments.topic(tournament.id))

      # Втроём при двух оплачиваемых местах баббл — с первой же раздачи,
      # но раздаёт один стол: синхронизировать не с кем.
      for {_id, table} <- :sys.get_state(pid).tables do
        deal_hand(table)
        play_hand(table)
      end

      refute_received {:tournament_event, "hand_for_hand", %{active: true}}
    end

    test "турнир на 2-Max доигрывается до победителя", _ctx do
      setting = fast_setting(%{table_size: 2, min_players: 2})
      tournament = tournament_fixture(setting)

      for _index <- 1..3,
          do: {:ok, _entry} = Tournaments.register(tournament.id, user_fixture().id)

      pid = start_server(tournament.id)
      :ok = TournamentServer.start_tournament(pid)

      assert :finished = play_tables_until_finished(pid)

      entries = Tournaments.list_entries(tournament.id)
      assert Enum.map(entries, & &1.place) |> Enum.sort() == [1, 2, 3]
    end
  end

  describe "подготовка до старта" do
    test "за минуту до старта игроки уже за столом, но карт нет", ctx do
      tournament = tournament_fixture(ctx.setting)

      users = for _index <- 1..2, do: user_fixture()
      for user <- users, do: {:ok, _entry} = Tournaments.register(tournament.id, user.id)

      pid = start_server(tournament.id)
      :ok = TournamentServer.prepare(pid)

      [{_id, table}] = Map.to_list(:sys.get_state(pid).tables)
      state = TableServer.state(table)

      # Места розданы...
      for user <- users, do: assert(RoomState.find_seat(state, user.id).stack == 5000)
      # ...а раздача не идёт: турнир ещё не начался.
      assert state.hand == nil

      # Повторная подготовка второго набора столов не поднимает.
      :ok = TournamentServer.prepare(pid)
      assert map_size(:sys.get_state(pid).tables) == 1

      :ok = TournamentServer.start_tournament(pid)
      assert TournamentServer.state(pid).players_left == 2

      # Отпущенный стол играет как обычный: кнопка разыгрывается, раздачи
      # идут одна за другой — не одна-единственная.
      deal_hand(table)
      assert TableServer.state(table).hand != nil

      play_hand(table)
      deal_hand(table)
      assert TableServer.state(table).hand != nil
    end

    test "отписавшийся после подготовки освобождает место", ctx do
      tournament = tournament_fixture(ctx.setting)

      users = for _index <- 1..3, do: user_fixture()
      for user <- users, do: {:ok, _entry} = Tournaments.register(tournament.id, user.id)

      pid = start_server(tournament.id)
      :ok = TournamentServer.prepare(pid)

      quitter = List.last(users)
      :ok = Tournaments.unregister(tournament.id, quitter.id)

      [{_id, table}] = Map.to_list(:sys.get_state(pid).tables)

      assert table |> TableServer.state() |> RoomState.find_seat(quitter.id) == nil
    end
  end

  describe "перерыв" do
    # 2-Max без ребая: обнулившийся вылетает сразу, а не остаётся за
    # столом с правом докупки — сценарию нужен именно вылет.
    defp heads_up_setting do
      levels = [
        %{
          level: 1,
          small_blind: 1000,
          big_blind: 2000,
          ante: 0,
          duration_seconds: 600,
          rebuy_allowed: false,
          addon_allowed: false
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
        %{
          table_size: 2,
          min_players: 2,
          buy_in: 1000,
          entry_fee: 100,
          starting_stack: 2000
        },
        levels
      )
    end

    # Доводит турнир до вылета, случившегося **на перерыве**: раздача
    # начата до XX:55 и доиграна уже на нём.
    defp bust_on_break(pid, limit \\ 10) do
      Enum.reduce_while(1..limit, :playing, fn _index, _acc ->
        tables = Map.values(:sys.get_state(pid).tables)

        for table <- tables, do: deal_hand(table)

        :ok = TournamentServer.fire(pid, :break)

        for table <- tables, do: play_hand(table)

        sync_tournament(pid)

        if TournamentServer.state(pid).players_left < 3 do
          {:halt, :busted}
        else
          :ok = TournamentServer.fire(pid, :break_over)
          {:cont, :playing}
        end
      end)
    end

    test "доигранная на перерыве раздача не тянет за собой следующую", _ctx do
      setting = fast_setting()
      tournament = tournament_fixture(setting)

      for _index <- 1..2,
          do: {:ok, _entry} = Tournaments.register(tournament.id, user_fixture().id)

      pid = start_server(tournament.id)
      :ok = TournamentServer.start_tournament(pid)

      [{_id, table}] = Map.to_list(:sys.get_state(pid).tables)

      # Перерыв объявлен посреди раздачи: она доигрывается, и вот этот
      # момент и проверяется — следующую она за собой не тянет.
      deal_hand(table)
      assert TableServer.state(table).hand != nil

      :ok = TournamentServer.fire(pid, :break)
      play_hand(table)

      assert TableServer.state(table).hand == nil
      refute Map.has_key?(:sys.get_state(table).timers, :next_hand)

      # И даже севший на перерыве игрок раздачу не начинает.
      :ok = TournamentServer.fire(pid, :break_over)
      assert TableServer.state(table).hand != nil
    end

    test "пересадка, назревшая за перерыв, случается по его концу", _ctx do
      # Стек равен большому блайнду: первая же раздача идёт на всё, и
      # вылет случается ровно на перерыве.
      setting = heads_up_setting()
      tournament = tournament_fixture(setting)

      for _index <- 1..3,
          do: {:ok, _entry} = Tournaments.register(tournament.id, user_fixture().id)

      pid = start_server(tournament.id, room_opts: [timers: :manual, rng: Rng.seeded(<<1>>)])
      :ok = TournamentServer.start_tournament(pid)

      # Раздача идёт, посреди неё объявляется перерыв, и она доигрывается
      # уже на нём. Раздача на всё чаще всего кончается вылетом, но может
      # и разделить банк, — поэтому перерывов столько, сколько нужно до
      # первого вылета на перерыве.
      bust_on_break(pid)

      # Двое на два стола: раздать не может ни один. Пересадку на
      # перерыве турнир не делает — но обязан сделать по его концу,
      # иначе `hand_finished` больше не придёт ниоткуда и турнир
      # останется стоять навсегда.
      assert TournamentServer.state(pid).players_left == 2

      :ok = TournamentServer.fire(pid, :break_over)

      assert play_tables_until_finished(pid) == :finished
    end
  end

  describe "финальный стол" do
    test "схлопывание до одного стола объявляет финалку и красит стол", _ctx do
      # Четверо на двухместных столах — это два стола.
      setting = fast_setting(%{table_size: 2, min_players: 2})
      tournament = tournament_fixture(setting)

      for _index <- 1..4,
          do: {:ok, _entry} = Tournaments.register(tournament.id, user_fixture().id)

      pid = start_server(tournament.id)
      :ok = TournamentServer.start_tournament(pid)

      Phoenix.PubSub.subscribe(BlockPoker.PubSub, Tournaments.topic(tournament.id))

      assert map_size(:sys.get_state(pid).tables) == 2
      refute TournamentServer.state(pid).final_table

      # Играем, пока живых не станет двое: столов остаётся один, и он
      # финальный.
      play_tables_until(pid, fn state -> state.players_left <= 2 end)

      assert_received {:tournament_event, "final_table", %{table_id: table_id}}

      state = :sys.get_state(pid)
      assert state.final_table == table_id
      assert state.status == :finishing

      # Стол знает, что он финальный, и берёт вторую пару цветов:
      # это решение турнира, а не настройка комнаты.
      {:ok, table} = Map.fetch(state.tables, table_id)
      assert TableServer.state(table).setting.final?
    end

    test "финалка объявляется один раз, а не на каждой раздаче", _ctx do
      setting = fast_setting(%{table_size: 2, min_players: 2})
      tournament = tournament_fixture(setting)

      for _index <- 1..4,
          do: {:ok, _entry} = Tournaments.register(tournament.id, user_fixture().id)

      pid = start_server(tournament.id)
      :ok = TournamentServer.start_tournament(pid)

      Phoenix.PubSub.subscribe(BlockPoker.PubSub, Tournaments.topic(tournament.id))

      # Доходим до финалки и играем дальше: объявление — событие, а не
      # состояние, и повторяться на каждой раздаче оно не должно.
      play_tables_until(pid, &(&1.final_table != nil))
      assert TournamentServer.state(pid).final_table

      play_tables_until(pid, fn state -> state.players_left < 2 end, 10)

      announcements =
        receive_all()
        |> Enum.count(fn {event, _payload} -> event == "final_table" end)

      assert announcements == 1
    end
  end

  describe "PKO" do
    # Прогрессивный баунти: половина головы деньгами, половина — на
    # собственную голову убийцы. Проверяется на живом турнире, а не на
    # чистой функции: тому есть свои тесты (`Engine.Bounty`), а здесь
    # важно, что выросшая голова доживает до следующего вылета.
    test "голова убийцы растёт и достаётся тому, кто выбьет уже его", _ctx do
      setting = fast_setting(%{table_size: 6, min_players: 2, bounty_part: 400})
      tournament = tournament_fixture(setting)

      users = for _index <- 1..3, do: user_fixture()
      for user <- users, do: {:ok, _entry} = Tournaments.register(tournament.id, user.id)

      pid = start_server(tournament.id)
      :ok = TournamentServer.start_tournament(pid)

      [{_id, table}] = Map.to_list(:sys.get_state(pid).tables)

      # Стартовая голова у всех одинаковая — цена головы шаблона.
      assert Enum.all?(TournamentServer.players(pid), &(&1.bounty == 400))

      play_hands_until(pid, table, &(&1.players_left < 3))

      # Кто-то выбил: голова убийцы выросла на половину чужой. Сколько
      # именно вылетов случилось в этой раздаче, тесту неважно — важно,
      # что каждая снятая голова легла половиной на голову убийцы, а
      # головы вылетевших с ними и ушли.
      players = TournamentServer.players(pid)
      busted = 3 - TournamentServer.state(pid).players_left

      assert busted > 0

      # Головы всех трёх входов: у каждого своя (400) плюс половина
      # чужой у каждого убийцы.
      assert Enum.sum(Enum.map(players, & &1.bounty)) == 400 * 3 + 200 * busted

      :finished = play_until_finished(pid, table)

      # Деньги не появились и не исчезли: собрано три взноса, выплачено
      # ровно столько же — призами и головами.
      assert Enum.sum(Enum.map(users, &balance/1)) == 3 * (10_000 - 100)
    end

    test "фиксированный баунти голову убийцы не растит", _ctx do
      setting =
        fast_setting(%{
          table_size: 6,
          min_players: 2,
          bounty_part: 400,
          bounty_progressive: false
        })

      tournament = tournament_fixture(setting)

      users = for _index <- 1..3, do: user_fixture()
      for user <- users, do: {:ok, _entry} = Tournaments.register(tournament.id, user.id)

      pid = start_server(tournament.id)
      :ok = TournamentServer.start_tournament(pid)

      [{_id, table}] = Map.to_list(:sys.get_state(pid).tables)

      play_hands_until(pid, table, &(&1.players_left < 3))

      # Вся голова ушла деньгами: голова убийцы осталась прежней.
      assert Enum.all?(TournamentServer.players(pid), &(&1.bounty == 400))
    end
  end

  describe "hand-for-hand на баббле" do
    # Баббл с двумя раздающими столами — единственная конфигурация, где
    # синхронный круг вообще нужен. Сетка платит троим уже при четырёх
    # входах, поэтому баббл здесь наступает сразу: четверо живых, три
    # оплачиваемых места, два стола по двое.
    defp bubble_payouts do
      [
        %{entries_from: 2, entries_to: 3, place_from: 1, place_to: 1, share_ppm: 1_000_000},
        %{entries_from: 4, entries_to: nil, place_from: 1, place_to: 1, share_ppm: 500_000},
        %{entries_from: 4, entries_to: nil, place_from: 2, place_to: 2, share_ppm: 300_000},
        %{entries_from: 4, entries_to: nil, place_from: 3, place_to: 3, share_ppm: 200_000}
      ]
    end

    defp bubble_levels(big_blind) do
      [
        %{
          level: 1,
          small_blind: div(big_blind, 2),
          big_blind: big_blind,
          ante: 0,
          duration_seconds: 600,
          rebuy_allowed: false,
          addon_allowed: false
        },
        %{
          level: 2,
          small_blind: big_blind,
          big_blind: big_blind * 2,
          ante: 0,
          duration_seconds: 600,
          rebuy_allowed: false,
          addon_allowed: false
        }
      ]
    end

    defp start_bubble(big_blind) do
      setting =
        setting_fixture(
          %{
            table_size: 2,
            min_players: 2,
            buy_in: 1000,
            entry_fee: 100,
            starting_stack: 5000
          },
          bubble_levels(big_blind),
          bubble_payouts()
        )

      tournament = tournament_fixture(setting)

      for _index <- 1..4,
          do: {:ok, _entry} = Tournaments.register(tournament.id, user_fixture().id)

      pid = start_server(tournament.id)
      :ok = TournamentServer.start_tournament(pid)

      Phoenix.PubSub.subscribe(BlockPoker.PubSub, Tournaments.topic(tournament.id))

      # Баббл — с первой раздачи: четверо живых при трёх оплачиваемых
      # местах, и раздают оба стола.
      assert TournamentServer.state(pid).players_left == 4
      assert TournamentServer.state(pid).next_payout_place == 3

      %{tournament: tournament, pid: pid}
    end

    test "доигравший стол ждёт остальных, а не сдаёт следующую", _ctx do
      # Блайнды маленькие: за одну раздачу чек-коллом никто не вылетает,
      # и баббл посреди проверки не лопается.
      %{pid: pid} = start_bubble(50)

      [first, second] = Map.values(:sys.get_state(pid).tables)

      deal_hand(first)
      play_current_hand(first)
      sync_tournament(pid)

      assert TournamentServer.state(pid).hand_for_hand
      assert_received {:tournament_event, "hand_for_hand", %{active: true}}

      # Первый доиграл круг и стоит: второй ещё раздаёт, и узнать от
      # него, кто вылетел, первый не должен.
      assert TableServer.state(first).paused?
      refute TableServer.state(second).paused?

      deal_hand(second)
      play_current_hand(second)
      sync_tournament(pid)

      # Круг закончили все — оба отпущены одновременно.
      refute TableServer.state(first).paused?
      refute TableServer.state(second).paused?
    end

    test "на баббле не пересаживают", _ctx do
      %{pid: pid} = start_bubble(50)

      before = Map.keys(:sys.get_state(pid).tables)

      [first, second] = Map.values(:sys.get_state(pid).tables)

      for table <- [first, second] do
        deal_hand(table)
        play_current_hand(table)
        sync_tournament(pid)
      end

      # Пересадка меняет позицию относительно блайндов — ровно то, от
      # чего hand-for-hand и защищает. Столы остаются те же.
      assert Map.keys(:sys.get_state(pid).tables) == before
    end

    test "лопнувший баббл распускает синхронный круг", _ctx do
      # Блайнды кусаются, но одну раздачу стек переживает: круг успевает
      # начаться до первого вылета.
      %{pid: pid} = start_bubble(2000)

      [first | _rest] = Map.values(:sys.get_state(pid).tables)

      deal_hand(first)
      play_current_hand(first)
      sync_tournament(pid)

      assert TournamentServer.state(pid).hand_for_hand

      play_tables_until(pid, &(&1.players_left <= 3))
      sync_tournament(pid)

      # Кто-то вылетел — оставшиеся уже в деньгах, синхронизировать
      # больше нечего.
      refute TournamentServer.state(pid).hand_for_hand
      assert_received {:tournament_event, "hand_for_hand", %{active: false}}

      for {_id, table} <- :sys.get_state(pid).tables do
        refute TableServer.state(table).paused?
      end
    end
  end

  describe "балансировка" do
    # Пересадка снимает игрока с одного стола и сажает за другой. Между
    # этими двумя шагами фишки не лежат нигде — это единственное место в
    # турнире, где они могут пропасть совсем, и проверяется здесь именно
    # отказ посадки, а не удачная пересадка (её проверяют сценарии выше).
    test "неудавшаяся пересадка возвращает игрока за прежний стол, а не теряет фишки", _ctx do
      setting = fast_setting(%{table_size: 2, min_players: 2})
      tournament = tournament_fixture(setting)

      for _index <- 1..3,
          do: {:ok, _entry} = Tournaments.register(tournament.id, user_fixture().id)

      pid = start_server(tournament.id)
      :ok = TournamentServer.start_tournament(pid)

      # Трое на двухместных столах: пара играет, третий сидит один.
      tables = :sys.get_state(pid).tables
      assert map_size(tables) == 2

      {full_id, full} = Enum.find(tables, fn {_id, t} -> occupancy(t) == 2 end)
      {lonely_id, lonely} = Enum.find(tables, fn {_id, t} -> occupancy(t) == 1 end)

      chips_before = chips_at(full) + chips_at(lonely)

      # Разводим представление турнира с комнатой: турнир перестаёт
      # видеть одного из сидящих за полным столом и считает, что место
      # там свободно. Комната при этом полна — и посадка на это место
      # обязана провалиться.
      [ghost | _rest] =
        TournamentServer.players(pid) |> Enum.filter(&(&1.table_id == full_id))

      :sys.replace_state(pid, fn state ->
        %{state | players: Map.delete(state.players, ghost.entry_id)}
      end)

      alone = Enum.find(TournamentServer.players(pid), &(&1.table_id == lonely_id))
      assert alone

      # Конец раздачи — единственный момент, когда турнир пересаживает.
      send(pid, {:table_event, "hand_summary", hand_summary(lonely_id)})
      _sync = TournamentServer.state(pid)

      # Игрок вернулся туда, откуда его сняли, со своим стеком...
      seat = lonely |> TableServer.state() |> RoomState.find_seat(alone.user_id)

      assert seat
      assert seat.stack == 5000

      # ...и фишек в турнире ровно столько же, сколько было.
      assert chips_at(full) + chips_at(lonely) == chips_before

      # Турнир знает, за каким столом игрок сидит на самом деле.
      assert Enum.find(TournamentServer.players(pid), &(&1.entry_id == alone.entry_id)).table_id ==
               lonely_id
    end

    defp occupancy(table), do: table |> TableServer.state() |> RoomState.players() |> length()

    # Пустой отчёт о конце раздачи: вылетевших нет, банков нет. Нужен,
    # чтобы турнир принял решение о рассадке, не играя раздачу.
    defp hand_summary(room_id) do
      %{room_id: room_id, busted: [], pots: [], button_seat: 1, stacks: %{}}
    end
  end

  describe "падение стола" do
    # Комната `:temporary`: сама она не поднимется, и турнир обязан
    # пережить её падение — иначе один упавший стол уносит рассадку
    # всего турнира.
    test "турнир поднимает стол заново и сажает игроков с их стеками", _ctx do
      setting = fast_setting(%{table_size: 6, min_players: 2})
      tournament = tournament_fixture(setting)

      users = for _index <- 1..3, do: user_fixture()
      for user <- users, do: {:ok, _entry} = Tournaments.register(tournament.id, user.id)

      pid = start_server(tournament.id)
      :ok = TournamentServer.start_tournament(pid)

      Phoenix.PubSub.subscribe(BlockPoker.PubSub, Tournaments.topic(tournament.id))

      [{dead_id, table}] = Map.to_list(:sys.get_state(pid).tables)

      # Раздача сыграна: стеки разошлись, и именно их турнир обязан
      # перенести на новый стол.
      deal_hand(table)
      play_hand(table)
      sync_tournament(pid)

      stacks = Map.new(TournamentServer.players(pid), &{&1.user_id, &1.stack})

      Process.exit(table, :kill)

      # Падение доезжает до турнира сообщением `:DOWN` — его, в отличие
      # от таймеров, вручную не прогнать, поэтому здесь единственное
      # ожидание в наборе, и оно на сообщение, а не на сон.
      assert_receive {:tournament_event, "table_recovered", %{table_id: ^dead_id}}

      # Турнир жив.
      assert Process.alive?(pid)
      _sync = TournamentServer.state(pid)

      [{new_id, new_table}] = Map.to_list(:sys.get_state(pid).tables)
      refute new_id == dead_id

      room = TableServer.state(new_table)

      for user <- users do
        seat = RoomState.find_seat(room, user.id)

        assert seat, "игрок #{user.id} не сел за поднятый стол"
        assert seat.stack == Map.fetch!(stacks, user.id)
      end

      # И турнир доигрывается: поднятый стол — обычный стол.
      assert :finished = play_until_finished(pid, new_table)
    end
  end
end
