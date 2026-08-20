defmodule BlockPoker.Tables.TableServerTest do
  @moduledoc """
  Комната как процесс: атомарность посадки, таймеры, розыгрыш кнопки.
  Без БД и без реального времени.
  """

  use ExUnit.Case, async: true

  import BlockPoker.TablesHelpers

  alias BlockPoker.Tables.{RoomState, TableServer}

  setup do
    ensure_tables!()
    :ok
  end

  describe "посадка" do
    test "два одновременных резерва на одно место: ровно один успех" do
      %{pid: pid} = start_room!()

      results =
        [1, 2]
        |> Enum.map(fn n ->
          Task.async(fn -> TableServer.reserve_seat(pid, "user-#{n}", 3, 400) end)
        end)
        |> Task.await_many()

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert {:error, :seat_taken} in results
    end

    test "бай-ин вне границ отвергается до резерва" do
      %{pid: pid} = start_room!()

      assert {:error, :invalid_buy_in} = TableServer.reserve_seat(pid, "user-1", 3, 100)
      # Резерва не осталось: место свободно.
      assert RoomState.free_seats(TableServer.state(pid)) == [1, 2, 3, 4, 5, 6]
    end

    test "quick_seat-путь: :first_free берёт первое свободное место" do
      %{pid: pid} = start_room!()
      seat!(pid, "user-1", 1, 400)

      {:ok, %{seat: seat}} = TableServer.reserve_seat(pid, "user-2", :first_free, 400)
      assert seat == 2
    end
  end

  describe "розыгрыш кнопки" do
    test "второй севший игрок запускает розыгрыш" do
      %{pid: pid, room_id: room_id} = start_room!()
      Phoenix.PubSub.subscribe(BlockPoker.PubSub, TableServer.topic(room_id))

      seat!(pid, "user-1", 1, 400)
      refute_received {:table_event, "button_draw", _payload}

      seat!(pid, "user-2", 4, 400)
      assert_received {:table_event, "button_draw", payload}

      assert payload.button_seat in [1, 4]
      assert length(payload.cards) == 2
      assert payload.animation_ms == 3000
    end

    test "с фиксированным seed кнопка достаётся тому же месту" do
      buttons =
        for _attempt <- 1..2 do
          %{pid: pid} = start_room!(%{}, seed: "постоянный")
          seat!(pid, "user-1", 1, 400)
          seat!(pid, "user-2", 4, 400)
          TableServer.state(pid).button_seat
        end

      assert [button, button] = buttons
    end

    test "раздача стартует не раньше конца button_draw_animation_ms" do
      %{pid: pid, room_id: room_id} = start_room!()
      Phoenix.PubSub.subscribe(BlockPoker.PubSub, TableServer.topic(room_id))

      seat!(pid, "user-1", 1, 400)
      seat!(pid, "user-2", 4, 400)

      # Пока таймер не сработал, комната остаётся в анимации.
      assert TableServer.state(pid).phase == :button_draw
      refute_received {:table_event, "button_ready", _payload}

      :ok = TableServer.fire_timer(pid, :button_draw)

      # Анимация кончилась — кнопка назначена и сразу началась раздача.
      assert TableServer.state(pid).phase == :hand
      assert_received {:table_event, "button_ready", _payload}
    end

    test "следующая раздача начинается и после того, как кнопка уже разыграна" do
      # Розыгрыш кнопки бывает один раз за стол, а раздач — много. Игрок,
      # подсевший позже, должен попадать в новую руку, а не в стоящий стол.
      %{pid: pid} = start_room!()

      seat!(pid, "user-1", 1, 400)
      seat!(pid, "user-2", 2, 400)
      :ok = TableServer.fire_timer(pid, :button_draw)
      assert TableServer.state(pid).phase == :hand

      play_hand_out(pid)
      assert TableServer.state(pid).hand == nil

      # Третий садится за уже начатый стол — рука стартует без нового розыгрыша.
      seat!(pid, "user-3", 3, 400)
      assert TableServer.state(pid).phase == :hand
    end

    test "кнопка переходит по кругу и не подвешивает стол" do
      # Кнопка на старшем месте — граничный случай: выбор следующей кнопки
      # обязан завершаться, иначе процесс стола зависает и все вызовы к нему
      # отваливаются по таймауту.
      %{pid: pid} = start_room!()

      seat!(pid, "user-1", 1, 400)
      seat!(pid, "user-2", 2, 400)
      :ok = TableServer.fire_timer(pid, :button_draw)

      button = TableServer.state(pid).button_seat
      assert button in [1, 2]

      play_hand_out(pid)

      # Стол по-прежнему отвечает, а кнопка сдвинулась на другое место.
      assert TableServer.state(pid).button_seat != button
    end

    test "розыгрыш проводится один раз, а не на каждого нового игрока" do
      %{pid: pid, room_id: room_id} = start_room!()
      seat!(pid, "user-1", 1, 400)
      seat!(pid, "user-2", 4, 400)
      button = TableServer.state(pid).button_seat

      Phoenix.PubSub.subscribe(BlockPoker.PubSub, TableServer.topic(room_id))
      seat!(pid, "user-3", 6, 400)

      refute_received {:table_event, "button_draw", _payload}
      assert TableServer.state(pid).button_seat == button
    end

    test "повторный сбор игроков после простоя запускает розыгрыш заново" do
      %{pid: pid} = start_room!()
      seat!(pid, "user-1", 1, 400)
      seat!(pid, "user-2", 4, 400)

      leave(pid, "user-2")
      assert TableServer.state(pid).button_seat == nil

      seat!(pid, "user-3", 5, 400)
      assert TableServer.state(pid).button_seat in [1, 5]
    end
  end

  describe "grace-период" do
    test "реконнект внутри окна возвращает игрока на место" do
      %{pid: pid} = start_room!()
      seat!(pid, "user-1", 2, 400)

      :ok = TableServer.disconnect(pid, "user-1")
      {:ok, seat} = TableServer.reconnect(pid, "user-1")

      assert seat.status == :playing
      assert seat.stack == 400
      # Таймер снят: истечь ему уже нечему.
      assert {:error, :no_such_timer} = TableServer.fire_timer(pid, {:grace, 2})
    end

    test "по истечении окна игрок уходит в sitting_out, место и фишки при нём" do
      %{pid: pid} = start_room!()
      seat!(pid, "user-1", 2, 400)

      :ok = TableServer.disconnect(pid, "user-1")
      :ok = TableServer.fire_timer(pid, {:grace, 2})

      room = TableServer.state(pid)
      assert Map.fetch!(room.seats, 2).status == :sitting_out
      assert RoomState.chips_in_play(room) == 400
    end
  end

  describe "изоляция и закрытие" do
    test "падение комнаты не задевает соседнюю" do
      %{pid: first} = start_room!()
      %{pid: second} = start_room!()

      Process.exit(first, :kill)

      assert Process.alive?(second)
      assert RoomState.free_seats(TableServer.state(second)) != []
    end

    test "в :draining комнату новых игроков не пускают" do
      %{pid: pid} = start_room!()
      :ok = TableServer.drain(pid)

      assert {:error, :room_closing} = TableServer.reserve_seat(pid, "user-1", 1, 400)
    end
  end

  describe "показатели сессии" do
    test "копятся по раздачам и уходят пушем в конце каждой" do
      %{pid: pid, room_id: room_id} = start_room!()
      Phoenix.PubSub.subscribe(BlockPoker.PubSub, TableServer.topic(room_id))

      seat!(pid, "user-1", 1, 400)
      seat!(pid, "user-2", 2, 400)
      :ok = TableServer.fire_timer(pid, :button_draw)

      play_hand_out(pid)
      assert_received {:table_event, "stats_update", payload}
      assert payload.seats[1].hands == 1

      :ok = TableServer.fire_timer(pid, :next_hand)
      play_hand_out(pid)

      room = TableServer.state(pid)
      assert room.seats[1].stats.hands == 2
      assert room.seats[2].stats.hands == 2
    end

    test "уход с места обнуляет сессию, а вынужденный сит-аут — нет" do
      %{pid: pid} = start_room!()

      seat!(pid, "user-1", 1, 400)
      seat!(pid, "user-2", 2, 400)
      :ok = TableServer.fire_timer(pid, :button_draw)
      play_hand_out(pid)

      # Отключение и сит-аут — не конец сессии: игрок остаётся за столом.
      {:ok, _} = TableServer.sit_out(pid, "user-1")
      assert TableServer.state(pid).seats[1].stats.hands == 1

      leave(pid, "user-1")
      seat!(pid, "user-1", 1, 400)

      assert TableServer.state(pid).seats[1].stats.hands == 0
    end

    test "показатели не достаются тому, кто сел на освободившееся место" do
      %{pid: pid} = start_room!()

      seat!(pid, "user-1", 1, 400)
      seat!(pid, "user-2", 2, 400)
      :ok = TableServer.fire_timer(pid, :button_draw)
      play_hand_out(pid)

      leave(pid, "user-1")
      seat!(pid, "user-3", 1, 400)

      assert TableServer.state(pid).seats[1].stats.hands == 0
    end
  end

  describe "тайм-банк" do
    defp start_hand_with_clock(players \\ 2) do
      {clock, advance} = manual_clock()
      %{pid: pid, room_id: room_id} = start_room!(%{}, clock: clock)

      for number <- 1..players, do: seat!(pid, "user-#{number}", number, 400)
      :ok = TableServer.fire_timer(pid, :button_draw)
      Phoenix.PubSub.subscribe(BlockPoker.PubSub, TableServer.topic(room_id))

      %{pid: pid, advance: advance}
    end

    defp acting_seat(pid) do
      room = TableServer.state(pid)
      Map.fetch!(room.seats, room.hand.to_act)
    end

    test "обычное время кончилось — включается банк, а не автофолд" do
      %{pid: pid} = start_hand_with_clock()
      before = acting_seat(pid)

      :ok = TableServer.fire_timer(pid, :action)

      assert_received {:table_event, "time_bank_started", payload}
      assert payload.seat == before.number
      assert payload.time_bank_ms == 30_000

      # Ход за игрока не сделан: очередь по-прежнему его.
      assert TableServer.state(pid).hand.to_act == before.number
    end

    test "списывается ровно продуманное сверх обычного времени" do
      %{pid: pid, advance: advance} = start_hand_with_clock()
      seat = acting_seat(pid)

      :ok = TableServer.fire_timer(pid, :action)
      advance.(4_500)
      :ok = TableServer.act(pid, seat.user_id, :call, nil)

      assert TableServer.state(pid).seats[seat.number].time_bank == 25_500
    end

    test "банк догорел — стол ходит за игрока" do
      %{pid: pid} = start_hand_with_clock()

      # Ход доводится до большого блайнда: за него бесплатный чек, поэтому
      # раздача продолжается и остаток банка видно до пополнения, которое
      # приходит только по её завершении.
      first = acting_seat(pid)
      :ok = TableServer.act(pid, first.user_id, :call, nil)
      seat = acting_seat(pid)

      :ok = TableServer.fire_timer(pid, :action)
      :ok = TableServer.fire_timer(pid, :action)

      room = TableServer.state(pid)
      assert room.hand.street == :flop
      assert room.seats[seat.number].time_bank == 0
    end

    test "за сыгранную раздачу банк пополняется, но не выше потолка" do
      %{pid: pid, advance: advance} = start_hand_with_clock()
      seat = acting_seat(pid)

      :ok = TableServer.fire_timer(pid, :action)
      advance.(15_000)
      :ok = TableServer.act(pid, seat.user_id, :call, nil)
      assert TableServer.state(pid).seats[seat.number].time_bank == 15_000

      play_hand_out(pid)

      # 15 000 + пополнение 10 000, потолок 30 000 не превышен.
      assert TableServer.state(pid).seats[seat.number].time_bank == 25_000
    end
  end

  describe "преселект" do
    defp two_handed_hand do
      %{pid: pid, room_id: room_id} = start_room!()
      seat!(pid, "user-1", 1, 400)
      seat!(pid, "user-2", 2, 400)
      :ok = TableServer.fire_timer(pid, :button_draw)
      Phoenix.PubSub.subscribe(BlockPoker.PubSub, TableServer.topic(room_id))

      room = TableServer.state(pid)
      acting = Map.fetch!(room.seats, room.hand.to_act)
      waiting = room.seats |> Map.values() |> Enum.find(&(&1.number != acting.number))

      %{pid: pid, acting: acting, waiting: waiting}
    end

    test "выбранный заранее фолд срабатывает, когда доходит очередь" do
      %{pid: pid, acting: acting, waiting: waiting} = two_handed_hand()

      :ok = TableServer.preselect(pid, waiting.user_id, :fold)
      :ok = TableServer.act(pid, acting.user_id, :call, nil)

      # Раздача закончилась, не дожидаясь второго игрока: за него сходил
      # его же выбор.
      assert TableServer.state(pid).hand == nil
      assert_received {:table_private, _user, "preselect_applied", %{action: :fold}}
    end

    test "чек против ставки снимает выбор, а не сбрасывает руку" do
      %{pid: pid, acting: acting, waiting: waiting} = two_handed_hand()

      :ok = TableServer.preselect(pid, waiting.user_id, :check)
      :ok = TableServer.act(pid, acting.user_id, {:raise, 40}, nil)

      room = TableServer.state(pid)

      assert room.hand.to_act == waiting.number
      assert room.seats[waiting.number].preselect == nil
      assert_received {:table_private, _user, "preselect_cleared", %{reason: "action_changed"}}
    end

    test "выбор, сделанный в свою очередь, срабатывает сразу" do
      %{pid: pid, acting: acting} = two_handed_hand()

      :ok = TableServer.preselect(pid, acting.user_id, :fold)

      assert TableServer.state(pid).hand == nil
    end

    test "новая улица снимает выбор" do
      %{pid: pid, acting: acting, waiting: waiting} = two_handed_hand()

      :ok = TableServer.preselect(pid, waiting.user_id, :call_any)
      :ok = TableServer.act(pid, acting.user_id, :call, nil)

      # Выбор сработал на префлопе и на флоп не перенёсся.
      room = TableServer.state(pid)
      assert room.hand.street == :flop
      assert Enum.all?(Map.values(room.seats), &(&1.preselect == nil))
    end
  end

  describe "чат" do
    test "сообщение уходит всем и попадает в историю комнаты" do
      %{pid: pid, room_id: room_id} = start_room!()
      seat!(pid, "user-1", 1, 400)
      Phoenix.PubSub.subscribe(BlockPoker.PubSub, TableServer.topic(room_id))

      assert {:ok, message} = TableServer.chat(pid, "user-1", "  привет   стол 
 ")

      assert message.text == "привет стол"
      assert message.seat == 1
      assert_received {:table_event, "chat_message", %{text: "привет стол"}}
      assert [%{text: "привет стол"}] = TableServer.state(pid).chat
    end

    test "наблюдатель писать не может" do
      %{pid: pid} = start_room!()
      seat!(pid, "user-1", 1, 400)

      assert {:error, :not_seated} = TableServer.chat(pid, "watcher", "всем привет")
    end

    test "флуд останавливается кодом, а не молча" do
      {clock, _advance} = manual_clock()
      %{pid: pid} = start_room!(%{}, clock: clock)
      seat!(pid, "user-1", 1, 400)

      for n <- 1..5 do
        assert {:ok, _message} = TableServer.chat(pid, "user-1", "сообщение #{n}")
      end

      assert {:error, :chat_rate_limited} = TableServer.chat(pid, "user-1", "ещё одно")
    end

    test "слишком длинное сообщение отвергается" do
      %{pid: pid} = start_room!()
      seat!(pid, "user-1", 1, 400)

      long = String.duplicate("я", BlockPoker.Chat.max_length() + 1)
      assert {:error, :chat_too_long} = TableServer.chat(pid, "user-1", long)
    end
  end

  describe "деньги на границе ухода" do
    # Сумма фишек в комнате: стеки мест плюс то, что лежит в банке идущей
    # раздачи. Ни один сценарий не вправе её изменить (§11 CLAUDE.md).
    defp chips_total(room) do
      RoomState.chips_in_play(room) + if room.hand, do: room.hand.pot, else: 0
    end

    defp all_in_hand(seed) do
      %{pid: pid} = start_room!(%{max_buy_in: nil}, seed: seed)
      seat!(pid, "user-1", 1, 400)
      seat!(pid, "user-2", 2, 400)
      :ok = TableServer.fire_timer(pid, :button_draw)

      room = TableServer.state(pid)
      first = Map.fetch!(room.seats, room.hand.to_act)
      :ok = TableServer.act(pid, first.user_id, :all_in, nil)

      room = TableServer.state(pid)
      second = room.seats |> Map.values() |> Enum.find(&(&1.number != first.number))
      :ok = TableServer.act(pid, second.user_id, :call, nil)

      %{pid: pid, all_in: first}
    end

    test "олл-ин игрок не может встать посреди раздачи" do
      # Стек места на олл-ине равен нулю, но игрок в раздаче и претендует
      # на банк: разрешить ему уйти — значит подарить банк пустому месту.
      %{pid: pid, all_in: seat} = all_in_hand("a")

      assert {:error, :hand_in_progress} = TableServer.begin_leave(pid, seat.user_id)
    end

    test "фишки не пропадают ни при одном раскладе доводки" do
      for seed <- ["a", "b", "c", "d", "e", "f"] do
        %{pid: pid, all_in: seat} = all_in_hand(seed)

        # Попытка уйти на олл-ине — та самая дырка.
        case TableServer.begin_leave(pid, seat.user_id) do
          {:ok, %{ref: ref}} -> TableServer.finish_leave(pid, ref)
          {:error, _reason} -> :ok
        end

        Enum.each(1..5, fn _step -> TableServer.fire_timer(pid, :runout) end)

        room = TableServer.state(pid)
        assert chips_total(room) == 800, "seed #{seed}: фишки разошлись"

        # И ни одной фишки на месте, за которым никто не сидит.
        assert Enum.all?(Map.values(room.seats), &(&1.user_id != nil or &1.stack == 0)),
               "seed #{seed}: фишки остались на пустом месте"
      end
    end

    test "докупка в момент ухода не съедает деньги" do
      %{pid: pid} = start_room!()
      seat!(pid, "user-1", 1, 400)
      seat!(pid, "user-2", 2, 400)

      # Стек уже уехал в кошелёк, подтверждения транзакции ещё нет.
      {:ok, %{ref: ref, stack: 400}} = TableServer.begin_leave(pid, "user-1")

      assert {:error, :leave_in_progress} = TableServer.begin_add_chips(pid, "user-1", 400)

      assert {:error, :leave_in_progress} =
               TableServer.commit_add_chips(pid, "user-1", "ref-1")

      :ok = TableServer.finish_leave(pid, ref)
      assert chips_total(TableServer.state(pid)) == 400
    end

    test "уходящее место не принимает ничего" do
      %{pid: pid} = start_room!()
      seat!(pid, "user-1", 1, 400)
      {:ok, %{ref: _ref}} = TableServer.begin_leave(pid, "user-1")

      assert {:error, :leave_in_progress} = TableServer.chat(pid, "user-1", "я всё")
      assert {:error, :leave_in_progress} = TableServer.preselect(pid, "user-1", :fold)
      assert {:error, :leave_in_progress} = TableServer.sit_out(pid, "user-1")
      assert {:error, :leave_in_progress} = TableServer.begin_leave(pid, "user-1")
    end
  end

  describe "кнопка и ждущие блайнда" do
    test "стол не падает, когда кнопка доходит до ждущего блайнда" do
      # Живой сценарий: двое играют, третий сел и ждёт большого блайнда.
      # Кнопка по кругу доходит до него — а раздачу по-прежнему играют двое.
      %{pid: pid} = start_room!()
      seat!(pid, "user-1", 1, 400)
      seat!(pid, "user-2", 2, 400)
      :ok = TableServer.fire_timer(pid, :button_draw)
      seat!(pid, "user-3", 3, 400)

      assert TableServer.state(pid).seats[3].waiting_for_bb

      # Несколько кругов: кнопка обязана пройти через место ждущего.
      for _hand <- 1..6 do
        play_hand_out(pid)
        assert Process.alive?(pid), "комната упала на смене раздачи"
        :ok = TableServer.fire_timer(pid, :next_hand)
      end

      room = TableServer.state(pid)
      assert room.phase == :hand, "стол встал и новую раздачу не начал"
      assert room.hands_played >= 6
    end

    test "кнопка не встаёт на место, которое не играет раздачу" do
      %{pid: pid} = start_room!()
      seat!(pid, "user-1", 1, 400)
      seat!(pid, "user-2", 2, 400)
      :ok = TableServer.fire_timer(pid, :button_draw)
      seat!(pid, "user-3", 3, 400)

      for _hand <- 1..6 do
        room = TableServer.state(pid)

        if room.hand do
          assert Map.has_key?(room.hand.players, room.button_seat),
                 "кнопка на месте #{room.button_seat}, которого нет в раздаче"
        end

        play_hand_out(pid)
        :ok = TableServer.fire_timer(pid, :next_hand)
      end
    end
  end

  describe "вход за взнос" do
    defp seated_and_waiting do
      %{pid: pid} = start_room!()
      seat!(pid, "user-1", 1, 400)
      seat!(pid, "user-2", 2, 400)
      :ok = TableServer.fire_timer(pid, :button_draw)
      seat!(pid, "user-3", 4, 400)

      seat = TableServer.state(pid).seats[4]
      assert seat.waiting_for_bb, "третий должен ждать большого блайнда"

      %{pid: pid}
    end

    test "нажатие «не ждать» вводит игрока в ближайшую раздачу" do
      %{pid: pid} = seated_and_waiting()

      assert :ok = TableServer.request_post(pid, "user-3", true)
      # Пока раздача идёт, это только намерение.
      assert TableServer.state(pid).seats[4].wants_post

      play_hand_out(pid)
      :ok = TableServer.fire_timer(pid, :next_hand)

      room = TableServer.state(pid)
      seat = room.seats[4]

      refute seat.waiting_for_bb
      refute seat.wants_post
      assert Map.has_key?(room.hand.players, 4), "игрок так и не попал в раздачу"
    end

    test "взнос уходит в банк, а не появляется из воздуха" do
      %{pid: pid} = seated_and_waiting()
      :ok = TableServer.request_post(pid, "user-3", true)

      play_hand_out(pid)
      :ok = TableServer.fire_timer(pid, :next_hand)

      room = TableServer.state(pid)
      total = RoomState.chips_in_play(room) + room.hand.pot

      assert total == 1200, "фишки разошлись: #{total}"
      # Заплатил за вход — стек меньше исходного.
      assert room.seats[4].stack < 400
    end

    test "намерение можно снять" do
      %{pid: pid} = seated_and_waiting()

      assert :ok = TableServer.request_post(pid, "user-3", true)
      assert :ok = TableServer.request_post(pid, "user-3", false)

      play_hand_out(pid)
      :ok = TableServer.fire_timer(pid, :next_hand)

      # Ждёт дальше, взнос не списан.
      room = TableServer.state(pid)
      assert room.seats[4].waiting_for_bb
      assert room.seats[4].stack == 400
    end

    test "играющему кнопка «не ждать» недоступна" do
      %{pid: pid} = seated_and_waiting()

      assert {:error, :post_not_available} = TableServer.request_post(pid, "user-1", true)
      assert {:error, :not_seated} = TableServer.request_post(pid, "watcher", true)
    end

    test "взнос одноразовый и на следующую раздачу не переносится" do
      %{pid: pid} = seated_and_waiting()
      :ok = TableServer.request_post(pid, "user-3", true)

      play_hand_out(pid)
      :ok = TableServer.fire_timer(pid, :next_hand)
      stack_after_entry = TableServer.state(pid).seats[4].stack

      play_hand_out(pid)

      room = TableServer.state(pid)
      assert room.seats[4].post == 0
      assert room.seats[4].dead_post == 0

      # Второй раз за вход он не платит: разница только на блайндах раздачи.
      assert RoomState.chips_in_play(room) == 1200
      assert is_integer(stack_after_entry)
    end
  end

  describe "кнопка между раздачами" do
    test "кнопка не остаётся на месте, покинутом между раздачами" do
      %{pid: pid} = start_room!()
      seat!(pid, "user-1", 1, 400)
      seat!(pid, "user-2", 3, 400)
      seat!(pid, "user-3", 5, 400)
      seat!(pid, "user-4", 6, 400)

      # Несколько раздач подряд: подсевшие ждут большого блайнда, и пока он
      # до них не дошёл, за столом играют не все. Уход кнопки виден только
      # когда оставшихся хватает на раздачу без неё.
      :ok = TableServer.fire_timer(pid, :button_draw)
      play_hand_out(pid)

      for _hand <- 1..4 do
        :ok = TableServer.fire_timer(pid, :next_hand)
        play_hand_out(pid)
      end

      room = TableServer.state(pid)
      button = room.button_seat
      leaving = Map.fetch!(room.seats, button)

      # Уход разрешён между раздачами — и уходит именно тот, на ком кнопка.
      leave(pid, leaving.user_id)

      :ok = TableServer.fire_timer(pid, :next_hand)
      room = TableServer.state(pid)

      assert room.hand != nil, "раздача не началась"
      refute room.button_seat == button, "кнопка осталась на пустом месте"

      assert Map.has_key?(room.hand.players, room.button_seat),
             "кнопка на месте, которое раздачу не играет"
    end
  end

  describe "идемпотентность докупки" do
    setup do
      # Без автостарта: проверяется докупка, и раздача, начавшаяся под рукой,
      # меняла бы стеки блайндами.
      %{pid: pid} = start_room!(%{auto_start: false})
      seat!(pid, "user-1", 1, 400)
      seat!(pid, "user-2", 2, 400)
      %{pid: pid}
    end

    test "двойной клик до зачисления получает тот же ключ", %{pid: pid} do
      {:ok, first} = TableServer.begin_add_chips(pid, "user-1", 100)
      {:ok, second} = TableServer.begin_add_chips(pid, "user-1", 100)

      assert first == second, "второй клик выдал новый ключ — это второе списание"
    end

    test "зачисление по ключу происходит ровно один раз", %{pid: pid} do
      {:ok, ref} = TableServer.begin_add_chips(pid, "user-1", 100)

      assert {:ok, seat} = TableServer.commit_add_chips(pid, "user-1", ref)
      assert seat.stack == 500

      assert {:already_credited, seat} = TableServer.commit_add_chips(pid, "user-1", ref)
      assert seat.stack == 500, "повтор зачислил фишки второй раз"
      assert RoomState.chips_in_play(TableServer.state(pid)) == 900
    end

    test "другая сумма поверх незавершённой докупки отклоняется", %{pid: pid} do
      {:ok, _ref} = TableServer.begin_add_chips(pid, "user-1", 100)

      assert {:error, :add_chips_in_progress} = TableServer.begin_add_chips(pid, "user-1", 200)
    end

    test "сорвавшаяся докупка освобождает ключ", %{pid: pid} do
      {:ok, ref} = TableServer.begin_add_chips(pid, "user-1", 100)
      :ok = TableServer.abort_add_chips(pid, "user-1", ref)

      assert {:ok, other} = TableServer.begin_add_chips(pid, "user-1", 200)
      refute other == ref
    end

    test "после зачисления докупаться можно снова", %{pid: pid} do
      {:ok, ref} = TableServer.begin_add_chips(pid, "user-1", 100)
      {:ok, _seat} = TableServer.commit_add_chips(pid, "user-1", ref)

      assert {:ok, next} = TableServer.begin_add_chips(pid, "user-1", 100)
      refute next == ref
      assert {:ok, seat} = TableServer.commit_add_chips(pid, "user-1", next)
      assert seat.stack == 600
    end
  end

  describe "закрытие комнаты" do
    test "пустая комната запирается и больше никого не сажает" do
      %{pid: pid} = start_room!()

      assert :ok = TableServer.close_if_idle(pid)
      assert TableServer.state(pid).draining?
      assert {:error, :room_closing} = TableServer.reserve_seat(pid, "user-1", 1, 400)
    end

    test "комната с зарезервированным местом закрыться не даёт" do
      %{pid: pid} = start_room!()
      {:ok, _reservation} = TableServer.reserve_seat(pid, "user-1", 1, 400)

      # Лобби об этом резерве ещё не знает: снапшот занятости приезжает
      # броадкастом и отстаёт. Решает комната, и она отказывает.
      assert {:error, :busy} = TableServer.close_if_idle(pid)
      refute TableServer.state(pid).draining?
    end

    test "комната с фишками на уходящем месте закрыться не даёт" do
      %{pid: pid} = start_room!()
      seat!(pid, "user-1", 1, 400)
      {:ok, %{ref: ref}} = TableServer.begin_leave(pid, "user-1")

      assert {:error, :busy} = TableServer.close_if_idle(pid)

      :ok = TableServer.finish_leave(pid, ref)
      assert :ok = TableServer.close_if_idle(pid)
    end
  end

  defp leave(pid, user_id) do
    {:ok, %{ref: ref}} = TableServer.begin_leave(pid, user_id)
    :ok = TableServer.finish_leave(pid, ref)
  end

  # Доигрывает текущую раздачу самыми простыми ходами.
  defp play_hand_out(pid) do
    Enum.reduce_while(1..60, :playing, fn _step, _acc ->
      room = TableServer.state(pid)

      case room.hand do
        nil ->
          {:halt, :done}

        hand ->
          seat = Map.fetch!(room.seats, hand.to_act)

          action =
            if hand.bet == Map.fetch!(hand.players, hand.to_act).committed,
              do: :check,
              else: :call

          :ok = TableServer.act(pid, seat.user_id, action, nil)
          {:cont, :playing}
      end
    end)
  end
end
