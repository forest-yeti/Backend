defmodule BlockPoker.Tables.TournamentTest do
  @moduledoc """
  Турнирный стол как процесс: приз, растущие блайнды, вылет вместо докупки.

  Без БД и без реального времени: часы инжектируются, таймеры прогоняются
  вручную (§11 CLAUDE.md).
  """

  use ExUnit.Case, async: true

  import BlockPoker.TablesHelpers

  alias BlockPoker.SitAndGoFixtures
  alias BlockPoker.Tables.{RoomState, TableServer}

  @stack 500

  setup do
    ensure_tables!()
    :ok
  end

  defp seat_all(pid, count) do
    for number <- 1..count, do: seat!(pid, "user-#{number}", number, @stack)
  end

  describe "политика режима" do
    test "встать из-за стола нельзя: место — это позиция в структуре" do
      %{pid: pid} = start_tournament_room!()
      seat_all(pid, 3)

      assert {:error, :hand_in_progress} = TableServer.begin_leave(pid, "user-1")
    end

    test "стек может быть только стартовым" do
      %{pid: pid} = start_tournament_room!()

      assert {:error, :invalid_buy_in} = TableServer.reserve_seat(pid, "user-1", 1, @stack - 1)
      assert {:error, :invalid_buy_in} = TableServer.reserve_seat(pid, "user-1", 1, @stack + 1)
      assert {:ok, _} = TableServer.reserve_seat(pid, "user-1", 1, @stack)
    end

    test "страддла, бомб-пота и run it twice в турнире нет" do
      %{pid: pid} = start_tournament_room!()
      seat_all(pid, 3)

      room = TableServer.state(pid)

      refute room.straddle_allowed?
      assert room.mode.bomb_pot(room) == nil
      refute room.mode.run_it_twice?(room)
      refute room.mode.straddle?(room)
    end

    test "рейка с банка нет ни при каком размере" do
      %{pid: pid, setting: setting} = start_tournament_room!()
      room = TableServer.state(pid)

      assert room.mode.rake(setting, 1_000_000, 6) == 0
    end
  end

  describe "призовой фонд" do
    test "приз тянется до первой раздачи и уходит в топик стола" do
      %{pid: pid, room_id: room_id} = start_tournament_room!()
      Phoenix.PubSub.subscribe(BlockPoker.PubSub, TableServer.topic(room_id))

      seat_all(pid, 3)
      TableServer.fire_timer(pid, :button_draw)

      assert_received {:table_event, "prize_revealed", prize}

      # Вырожденная таблица фикстуры: x2 при взносе 100 — фонд 200.
      assert prize.multiplier == 200
      assert prize.label == "x2"
      assert prize.pool == 200
      assert prize.payouts == [100]
    end

    test "приз тянется один раз за турнир, а не каждую раздачу" do
      %{pid: pid, room_id: room_id} = start_tournament_room!()
      Phoenix.PubSub.subscribe(BlockPoker.PubSub, TableServer.topic(room_id))

      seat_all(pid, 3)
      TableServer.fire_timer(pid, :button_draw)
      assert_received {:table_event, "prize_revealed", _prize}

      drawn = TableServer.state(pid).tournament.prize

      # Прогон ещё одной раздачи приз не переигрывает.
      play_hand_out(pid)

      refute_received {:table_event, "prize_revealed", _second}
      assert TableServer.state(pid).tournament.prize == drawn
    end

    test "фонд считается от взноса, а не от суммы взносов" do
      # x10 при взносе 100 — фонд 1000, независимо от того, что за столом
      # трое и внесено 300.
      %{pid: pid} =
        start_tournament_room!(%{
          prize_tiers:
            SitAndGoFixtures.prize_tiers([
              %{multiplier: 1_000, chance_ppm: 1_000_000, payouts: [75, 20, 5]}
            ])
        })

      seat_all(pid, 3)
      TableServer.fire_timer(pid, :button_draw)

      assert TableServer.state(pid).tournament.prize.pool == 1_000
    end
  end

  describe "структура уровней" do
    test "турнир начинается с первого уровня" do
      %{pid: pid} = start_tournament_room!()
      seat_all(pid, 3)

      level = RoomState.current_level(TableServer.state(pid))

      assert level.level == 1
      assert level.small_blind == 10
      assert level.big_blind == 20
    end

    test "уровень поднимается по истечении времени — между раздачами" do
      {clock, advance} = manual_clock()

      %{pid: pid, room_id: room_id} =
        start_tournament_room!(
          %{blind_levels: SitAndGoFixtures.blind_levels(duration_seconds: 60)},
          clock: clock
        )

      Phoenix.PubSub.subscribe(BlockPoker.PubSub, TableServer.topic(room_id))
      seat_all(pid, 3)
      TableServer.fire_timer(pid, :button_draw)

      assert TableServer.state(pid).tournament.level == 1

      # Минута прошла: следующая раздача идёт уже на втором уровне.
      advance.(60_000)
      play_hand_out(pid)

      assert_received {:table_event, "level_up", payload}
      assert payload.level == 2
      assert payload.big_blind == 30
      assert TableServer.state(pid).tournament.level == 2
    end

    test "уровень не растёт, пока время не вышло" do
      {clock, advance} = manual_clock()

      %{pid: pid} =
        start_tournament_room!(
          %{blind_levels: SitAndGoFixtures.blind_levels(duration_seconds: 60)},
          clock: clock
        )

      seat_all(pid, 3)
      TableServer.fire_timer(pid, :button_draw)

      advance.(59_999)
      play_hand_out(pid)

      assert TableServer.state(pid).tournament.level == 1
    end

    test "длинная раздача не съедает пропущенные уровни: догоняются все" do
      {clock, advance} = manual_clock()

      %{pid: pid} =
        start_tournament_room!(
          %{blind_levels: SitAndGoFixtures.blind_levels(duration_seconds: 60)},
          clock: clock
        )

      seat_all(pid, 3)
      TableServer.fire_timer(pid, :button_draw)

      # Две минуты в одной раздаче — это два пропущенных уровня.
      advance.(120_000)
      play_hand_out(pid)

      assert TableServer.state(pid).tournament.level == 3
    end

    test "последний уровень действует до конца: расти больше некуда" do
      {clock, advance} = manual_clock()

      %{pid: pid} =
        start_tournament_room!(
          %{blind_levels: SitAndGoFixtures.blind_levels(duration_seconds: 60)},
          clock: clock
        )

      seat_all(pid, 3)
      TableServer.fire_timer(pid, :button_draw)

      advance.(600_000)
      play_hand_out(pid)

      state = TableServer.state(pid)

      assert state.tournament.level == 3
      assert state.tournament.level_deadline_at == nil
      assert RoomState.current_level(state).big_blind == 40
    end
  end

  describe "хедз-ап" do
    test "турнир на двоих стартует вдвоём и раздаёт карты" do
      %{pid: pid} = start_tournament_room!(%{max_players: 2})

      for number <- 1..2, do: seat!(pid, "user-#{number}", number, @stack)
      TableServer.fire_timer(pid, :button_draw)

      room = TableServer.state(pid)

      assert room.game_started?
      assert room.hand != nil
      assert map_size(room.hand.players) == 2
    end

    test "кнопка ставит малый блайнд и ходит первой до флопа" do
      # Правило хедз-апа, которое ломается чаще всего: за двухместным
      # столом кнопка и есть малый блайнд.
      %{pid: pid} = start_tournament_room!(%{max_players: 2})

      for number <- 1..2, do: seat!(pid, "user-#{number}", number, @stack)
      TableServer.fire_timer(pid, :button_draw)

      room = TableServer.state(pid)
      button = room.button_seat

      assert room.hand.to_act == button
      assert Map.fetch!(room.hand.players, button).committed == 10
    end

    test "приз тянется из таблицы 2-max: множитель ниже x2" do
      %{pid: pid} =
        start_tournament_room!(%{
          max_players: 2,
          prize_tiers:
            SitAndGoFixtures.prize_tiers([
              %{multiplier: 150, chance_ppm: 1_000_000, payouts: [100]}
            ])
        })

      for number <- 1..2, do: seat!(pid, "user-#{number}", number, @stack)
      TableServer.fire_timer(pid, :button_draw)

      prize = TableServer.state(pid).tournament.prize

      assert prize.label == "x1.5"
      # Взнос фикстуры — 100, фонд полтора взноса.
      assert prize.pool == 150
    end

    test "один игрок турнир не начинает" do
      %{pid: pid} = start_tournament_room!(%{max_players: 2})

      seat!(pid, "user-1", 1, @stack)

      refute TableServer.state(pid).game_started?
    end
  end

  describe "Short Deck" do
    test "уровни без блайндов задают анте кнопки" do
      %{pid: pid} =
        start_tournament_room!(%{
          game_type: :short_deck,
          blind_levels: SitAndGoFixtures.ante_levels()
        })

      seat_all(pid, 3)
      room = TableServer.state(pid)

      assert RoomState.current_level(room).ante == 10

      # Базовая единица анте-стола — само анте, а не большой блайнд.
      assert RoomState.bet_unit(room) == 10
    end
  end

  # Доигрывает раздачу до конца фолдами: подробности раздачи проверяются
  # в тестах движка, здесь важен только переход между раздачами.
  defp play_hand_out(pid) do
    fold_until_done(pid)

    # Пауза между раздачами — таймер стола; в тестах он прогоняется вручную.
    :ok = TableServer.fire_timer(pid, :next_hand)
  end

  defp fold_until_done(pid) do
    room = TableServer.state(pid)

    if room.hand do
      seat = Map.fetch!(room.seats, room.hand.to_act)
      :ok = TableServer.act(pid, seat.user_id, :fold, nil)
      fold_until_done(pid)
    else
      :ok
    end
  end
end
