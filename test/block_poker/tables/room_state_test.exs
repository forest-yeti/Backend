defmodule BlockPoker.Tables.RoomStateTest do
  @moduledoc """
  Состояние комнаты — чистые функции, поэтому тесты без процессов и без БД.
  """

  use ExUnit.Case, async: true

  import BlockPoker.CashGamesFixtures

  alias BlockPoker.Tables.{RoomState, Seat}

  setup do
    setting = build_setting(%{small_blind: 5, big_blind: 10, max_players: 6})
    %{room: RoomState.new(Ecto.UUID.generate(), setting), setting: setting}
  end

  describe "резерв места" do
    test "занимает место до похода в кошелёк", %{room: room} do
      {:ok, room} = RoomState.reserve(room, 3, "user-1", "res-1")

      assert %Seat{status: :reserved, user_id: "user-1"} = Map.fetch!(room.seats, 3)

      # Резерв — это занятость: место не должно достаться другому.
      assert RoomState.seats_taken(room) == 1
      refute 3 in RoomState.free_seats(room)
    end

    test "второй игрок на то же место получает seat_taken", %{room: room} do
      {:ok, room} = RoomState.reserve(room, 3, "user-1", "res-1")

      assert {:error, :seat_taken} = RoomState.reserve(room, 3, "user-2", "res-2")
    end

    test "один игрок — одно место в комнате", %{room: room} do
      {:ok, room} = RoomState.reserve(room, 3, "user-1", "res-1")

      assert {:error, :already_seated} = RoomState.reserve(room, 4, "user-1", "res-2")
    end

    test "несуществующее место отвергается", %{room: room} do
      assert {:error, :invalid_seat} = RoomState.reserve(room, 9, "user-1", "res-1")
    end

    test "в закрывающуюся комнату не сажаем", %{room: room} do
      room = RoomState.mark_draining(room)

      assert {:error, :room_closing} = RoomState.reserve(room, 1, "user-1", "res-1")
    end

    test "снятие резерва возвращает место свободным", %{room: room} do
      {:ok, room} = RoomState.reserve(room, 3, "user-1", "res-1")
      room = RoomState.release(room, "res-1")

      assert Seat.empty?(Map.fetch!(room.seats, 3))
      assert RoomState.chips_in_play(room) == 0
    end
  end

  describe "подтверждение посадки" do
    test "стек равен бай-ину, место занято", %{room: room} do
      {:ok, room} = RoomState.reserve(room, 3, "user-1", "res-1")
      {:ok, room, seat} = RoomState.confirm(room, "res-1", 400, :wait_bb)

      assert seat.stack == 400
      assert seat.status == :playing
      assert RoomState.chips_in_play(room) == 400
    end

    test "потерянный резерв не превращается в место", %{room: room} do
      assert {:error, :reservation_lost} = RoomState.confirm(room, "нет такого", 400, :wait_bb)
    end
  end

  describe "границы бай-ина" do
    test "меньше минимума отвергается", %{room: room} do
      # min_buy_in 40bb при bb=10 — это 400 фишек.
      assert {:error, :invalid_buy_in} = RoomState.validate_buy_in(room, 399)
      assert :ok = RoomState.validate_buy_in(room, 400)
    end

    test "докупка не может поднять стек выше максимума", %{room: room} do
      assert :ok = RoomState.validate_buy_in(room, 600, 400)
      assert {:error, :invalid_buy_in} = RoomState.validate_buy_in(room, 601, 400)
    end

    test "докупка обязана довести короткий стек до минимума" do
      # Баг: проигравший почти всё оставался с 5 фишками, докупал один
      # большой блайнд и садился играть на 1.5bb за столом с минимумом 40bb.
      setting = build_setting(%{big_blind: 10, min_buy_in: 40, max_buy_in: 100})
      room = RoomState.new(Ecto.UUID.generate(), setting)

      assert {:error, :invalid_buy_in} = RoomState.validate_buy_in(room, 10, 5)
      assert :ok = RoomState.validate_buy_in(room, 395, 5)
    end

    test "стек выше минимума докупается на любую сумму", %{room: room} do
      # Дошедший до минимума докупается как угодно: правило про нижнюю
      # границу стола, а не про размер докупки.
      assert :ok = RoomState.validate_buy_in(room, 1, 400)
    end

    test "стол без потолка принимает любую сумму сверх минимума" do
      setting = build_setting(%{big_blind: 10, max_buy_in: nil})
      room = RoomState.new(Ecto.UUID.generate(), setting)

      assert :ok = RoomState.validate_buy_in(room, 1_000_000)
    end
  end

  describe "уход из-за стола" do
    setup %{room: room} do
      {:ok, room} = RoomState.reserve(room, 2, "user-1", "res-1")
      {:ok, room, _seat} = RoomState.confirm(room, "res-1", 500, :wait_bb)
      %{room: room}
    end

    test "место держится, пока фишки в полёте", %{room: room} do
      {:ok, room, stack} = RoomState.begin_leave(room, "user-1", "ref-1")

      assert stack == 500

      # Место занято до подтверждения cash-out: отдать его другому нельзя.
      assert {:error, :seat_taken} = RoomState.reserve(room, 2, "user-2", "res-2")
      assert RoomState.chips_in_play(room) == 0
    end

    test "подтверждение освобождает место", %{room: room} do
      {:ok, room, _stack} = RoomState.begin_leave(room, "user-1", "ref-1")
      room = RoomState.finish_leave(room, "ref-1")

      assert Seat.empty?(Map.fetch!(room.seats, 2))
      assert RoomState.empty?(room)
    end

    test "неудача cash-out возвращает фишки на место", %{room: room} do
      {:ok, room, stack} = RoomState.begin_leave(room, "user-1", "ref-1")
      room = RoomState.cancel_leave(room, "ref-1", stack)

      assert Map.fetch!(room.seats, 2).stack == 500
      assert Map.fetch!(room.seats, 2).user_id == "user-1"
    end

    test "уходя, игрок попадает в окно возврата", %{room: room} do
      {:ok, room, _stack} = RoomState.begin_leave(room, "user-1", "ref-1")
      room = RoomState.finish_leave(room, "ref-1")

      # Сев обратно внутри окна, игрок теряет право ждать блайнда.
      room = %{room | button_seat: 1, big_blind_seat: 3}
      {:ok, room} = RoomState.reserve(room, 6, "user-1", "res-2")
      {:ok, _room, seat} = RoomState.confirm(room, "res-2", 500, :wait_bb)

      assert seat.post_required
    end
  end

  describe "разрыв связи" do
    setup %{room: room} do
      {:ok, room} = RoomState.reserve(room, 2, "user-1", "res-1")
      {:ok, room, _seat} = RoomState.confirm(room, "res-1", 500, :wait_bb)
      %{room: room}
    end

    test "место не освобождается и фишки остаются", %{room: room} do
      {:ok, room} = RoomState.disconnect(room, "user-1")

      assert Map.fetch!(room.seats, 2).status == :disconnected
      assert RoomState.chips_in_play(room) == 500
    end

    test "возврат ставит игрока обратно в игру", %{room: room} do
      {:ok, room} = RoomState.disconnect(room, "user-1")
      {:ok, room, seat} = RoomState.reconnect(room, "user-1")

      assert seat.status == :playing
      assert Map.fetch!(room.seats, 2).stack == 500
    end

    test "истёкший grace переводит в sitting_out, но место сохраняет", %{room: room} do
      {:ok, room} = RoomState.disconnect(room, "user-1")
      room = RoomState.expire_grace(room, 2)

      assert Map.fetch!(room.seats, 2).status == :sitting_out
      assert Map.fetch!(room.seats, 2).user_id == "user-1"
      assert RoomState.chips_in_play(room) == 500
    end
  end

  describe "нулевой стек" do
    setup %{room: room} do
      {:ok, room} = RoomState.reserve(room, 2, "user-1", "res-1")
      {:ok, room, _seat} = RoomState.confirm(room, "res-1", 500, :wait_bb)
      seats = Map.update!(room.seats, 2, &%{&1 | stack: 0})
      %{room: %{room | seats: seats}}
    end

    test "игрок уходит в sitting_out, но место остаётся за ним", %{room: room} do
      room = RoomState.zero_stack(room, 2)

      assert Map.fetch!(room.seats, 2).status == :sitting_out
      assert Map.fetch!(room.seats, 2).user_id == "user-1"
    end

    test "докупка возвращает его в игру", %{room: room} do
      room = RoomState.zero_stack(room, 2)
      {:ok, room, "ref-1"} = RoomState.begin_add_chips(room, "user-1", 400, "ref-1")
      {:ok, room, seat} = RoomState.commit_add_chips(room, "user-1", "ref-1")

      assert seat.status == :playing
      assert Map.fetch!(room.seats, 2).stack == 400
    end

    test "sit_in с нулевым стеком запрещён", %{room: room} do
      room = RoomState.zero_stack(room, 2)

      assert {:error, :zero_stack} = RoomState.sit_in(room, "user-1")
    end
  end

  test "докупка во время раздачи запрещена", %{room: room} do
    {:ok, room} = RoomState.reserve(room, 2, "user-1", "res-1")
    {:ok, room, _seat} = RoomState.confirm(room, "res-1", 500, :wait_bb)
    room = %{room | phase: :hand}

    assert {:error, :hand_in_progress} =
             RoomState.begin_add_chips(room, "user-1", 100, "ref-1")
  end

  test "комната закрывается только пустой и без фишек", %{room: room} do
    assert RoomState.closable?(room)

    {:ok, room} = RoomState.reserve(room, 1, "user-1", "res-1")
    refute RoomState.closable?(room)
  end
end
