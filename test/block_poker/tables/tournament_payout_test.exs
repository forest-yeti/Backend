defmodule BlockPoker.Tables.TournamentPayoutTest do
  @moduledoc """
  Конец турнира: места, выплаты и то, что деньги не удваиваются.

  Расчёт итогов — чистая функция режима, поэтому большая часть проверок
  идёт по собранному состоянию комнаты, без процессов и без БД.
  """

  use ExUnit.Case, async: true

  import BlockPoker.TablesHelpers

  alias BlockPoker.Engine.PrizePool
  alias BlockPoker.GameMode.Tournament
  alias BlockPoker.SitAndGo
  alias BlockPoker.SitAndGoFixtures
  alias BlockPoker.Tables.{RoomState, Seat, TableServer}

  setup do
    ensure_tables!()
    :ok
  end

  # Комната с рассаженными игроками, разыгранным призом и начатой игрой —
  # то состояние, из которого турнир доигрывается до конца.
  defp room(stacks, prize_tier) do
    setting =
      SitAndGoFixtures.build_setting(%{
        max_players: length(stacks),
        prize_tiers: SitAndGoFixtures.prize_tiers([prize_tier])
      })

    seats =
      stacks
      |> Enum.with_index(1)
      |> Map.new(fn {stack, number} ->
        {number, %{Seat.new(number) | status: :playing, user_id: "user-#{number}", stack: stack}}
      end)

    prize = %{
      multiplier: prize_tier.multiplier,
      label: PrizePool.multiplier_label(prize_tier.multiplier),
      pool: PrizePool.prize_pool(setting.buy_in, prize_tier.multiplier),
      payouts: prize_tier.payouts
    }

    Ecto.UUID.generate()
    |> RoomState.new(setting, Tournament)
    |> Map.put(:seats, seats)
    |> Map.put(:game_started?, true)
    |> RoomState.start_tournament(SitAndGo.blind_schedule(setting))
    |> RoomState.put_prize(prize)
  end

  defp winner_takes_all, do: %{multiplier: 200, chance_ppm: 1_000_000, payouts: [100]}
  defp three_paid, do: %{multiplier: 10_000, chance_ppm: 1_000_000, payouts: [75, 20, 5]}

  describe "признак конца" do
    test "пока живых больше одного, турнир не окончен" do
      refute Tournament.finished?(room([500, 500, 500], winner_takes_all()))
    end

    test "остался один живой — турнир требует расчёта" do
      assert Tournament.finished?(room([1500, 0, 0], winner_takes_all()))
    end

    test "нерасчитанным турнир считается ровно один раз" do
      state = room([1500, 0, 0], winner_takes_all())

      assert Tournament.finished?(state)
      refute state |> RoomState.settle_tournament() |> Tournament.finished?()
    end

    test "не начатый турнир не заканчивается, даже если за столом один" do
      state = %{room([500], winner_takes_all()) | game_started?: false}

      refute Tournament.finished?(state)
    end
  end

  describe "итоговая таблица" do
    test "победитель занимает первое место и забирает весь фонд" do
      state =
        room([1500, 0, 0], winner_takes_all())
        |> eliminate("user-3", 3)
        |> eliminate("user-2", 2)

      [first, second, third] = Tournament.results(state)

      assert %{place: 1, user_id: "user-1", amount: 200} = first
      assert %{place: 2, user_id: "user-2", amount: 0} = second
      assert %{place: 3, user_id: "user-3", amount: 0} = third
    end

    test "сумма выплат равна призовому фонду ровно" do
      state =
        room([1500, 0, 0], three_paid())
        |> eliminate("user-3", 3)
        |> eliminate("user-2", 2)

      results = Tournament.results(state)
      pool = state.tournament.prize.pool

      assert Enum.sum(Enum.map(results, & &1.amount)) == pool
      assert [7500, 2000, 500] == Enum.map(results, & &1.amount)
    end

    test "места вне призовой зоны получают ноль, а не отсутствуют" do
      state =
        room([1500, 0, 0], winner_takes_all())
        |> eliminate("user-3", 3)
        |> eliminate("user-2", 2)

      assert length(Tournament.results(state)) == 3
    end

    test "у недоигранного турнира победителя нет, но вылетевшие уже есть" do
      state = room([800, 700, 0], winner_takes_all()) |> eliminate("user-3", 3)

      # Пока живых двое, первое место не занято никем: записывать его
      # «заранее» значило бы фиксировать несуществующий факт.
      assert [%{place: 3, user_id: "user-3"}] = Tournament.results(state)
    end
  end

  describe "вылет" do
    test "первый вылетевший занимает последнее место" do
      state = room([500, 500, 500], winner_takes_all())
      seat = Map.fetch!(state.seats, 2)

      state = Tournament.on_zero_stack(state, seat)

      assert [%{seat: 2, place: 3}] = state.tournament.standings
    end

    test "места идут вверх по мере вылетов" do
      state = room([500, 500, 500], winner_takes_all())

      state = Tournament.on_zero_stack(state, Map.fetch!(state.seats, 2))
      state = Tournament.on_zero_stack(state, Map.fetch!(state.seats, 3))

      assert [%{seat: 3, place: 2}, %{seat: 2, place: 3}] = state.tournament.standings
    end

    test "вылетевший остаётся за столом: освобождать место в Sit & Go не для кого" do
      state = room([500, 500, 500], winner_takes_all())
      state = Tournament.on_zero_stack(state, Map.fetch!(state.seats, 2))

      assert Seat.taken?(Map.fetch!(state.seats, 2))
    end
  end

  describe "стол доигрывает турнир до конца" do
    test "остался один — стол объявляет итог и зовёт выплату ровно раз" do
      test_pid = self()
      {clock, advance} = manual_clock()

      %{pid: pid, room_id: room_id} =
        start_tournament_room!(
          %{
            starting_stack: 40,
            blind_levels: SitAndGoFixtures.blind_levels(duration_seconds: 60)
          },
          clock: clock,
          payout: fn _room, results -> send(test_pid, {:paid, results}) end
        )

      Phoenix.PubSub.subscribe(BlockPoker.PubSub, TableServer.topic(room_id))

      for number <- 1..3, do: seat!(pid, "user-#{number}", number, 40)
      TableServer.fire_timer(pid, :button_draw)

      # Стек в два больших блайнда, и время идёт: блайнды растут, съедают
      # стол за считанные раздачи, и турнир доигрывается сам. Без хода
      # часов сценарий из фолдов вечен — блайнд забирает свой же банк.
      play_until_finished(pid, 400, advance)

      assert_received {:table_event, "tournament_finished", payload}
      assert_received {:paid, results}

      assert length(results) == 3
      assert Enum.map(results, & &1.place) == [1, 2, 3]
      assert Enum.sum(Enum.map(results, & &1.amount)) == payload.prize.pool

      # Второго расчёта не будет: «остался один» — состояние, а не событие.
      refute_received {:paid, _second}
    end
  end

  describe "хедз-ап доигрывается до победителя" do
    test "на двоих победитель забирает фонд, проигравший получает прочерк" do
      test_pid = self()
      {clock, advance} = manual_clock()

      %{pid: pid, room_id: room_id} =
        start_tournament_room!(
          %{
            max_players: 2,
            starting_stack: 40,
            blind_levels: SitAndGoFixtures.blind_levels(duration_seconds: 60),
            # Таблица 2-max: основной множитель ниже x2 — этого требует
            # матожидание при двух участниках.
            prize_tiers:
              SitAndGoFixtures.prize_tiers([
                %{multiplier: 150, chance_ppm: 1_000_000, payouts: [100]}
              ])
          },
          clock: clock,
          payout: fn _room, results -> send(test_pid, {:paid, results}) end
        )

      Phoenix.PubSub.subscribe(BlockPoker.PubSub, TableServer.topic(room_id))

      for number <- 1..2, do: seat!(pid, "user-#{number}", number, 40)
      TableServer.fire_timer(pid, :button_draw)

      play_until_finished(pid, 400, advance)

      assert_received {:table_event, "tournament_finished", payload}
      assert_received {:paid, results}

      assert [first, second] = results
      assert first.place == 1
      assert first.amount == payload.prize.pool
      assert second.place == 2
      assert second.amount == 0
    end
  end

  defp eliminate(state, user_id, place) do
    seat = Enum.find(Map.values(state.seats), &(&1.user_id == user_id))

    RoomState.eliminate(state, seat, place)
  end

  # Доигрывает турнир до вскрытия каждой раздачи: все уравнивают, банк
  # достаётся сильнейшей руке. Фолдить здесь нельзя — при трёх игроках
  # блайнд забирал бы собственный банк, и никто бы не вылетел никогда.
  defp play_until_finished(pid, fuel, advance) when fuel > 0 do
    room = TableServer.state(pid)

    cond do
      room.tournament.settled? ->
        :ok

      room.hand && room.hand.to_act ->
        call_or_check(pid, room)
        play_until_finished(pid, fuel - 1, advance)

      room.hand ->
        # Хода ни за кем: все в олл-ине, идёт доводка борда.
        TableServer.fire_timer(pid, :runout)
        play_until_finished(pid, fuel - 1, advance)

      true ->
        advance.(60_000)
        TableServer.fire_timer(pid, :next_hand)
        play_until_finished(pid, fuel - 1, advance)
    end
  end

  defp play_until_finished(_pid, _fuel, _advance),
    do: flunk("турнир не закончился за отведённые раздачи")

  defp call_or_check(pid, room) do
    hand = room.hand
    seat = Map.fetch!(room.seats, hand.to_act)
    player = Map.fetch!(hand.players, hand.to_act)
    action = if hand.bet == player.committed, do: :check, else: :call

    :ok = TableServer.act(pid, seat.user_id, action, nil)
  end
end
