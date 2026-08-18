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
      :ok = TableServer.sit_out(pid, "user-1")
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
