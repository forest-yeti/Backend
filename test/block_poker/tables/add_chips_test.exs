defmodule BlockPoker.Tables.AddChipsTest do
  @moduledoc """
  Докупка во время раздачи: заявка сейчас, фишки — со следующей раздачей.

  Ловить паузу между раздачами игрок не обязан. Отказ «во время раздачи
  нельзя» защищал ровно одно — эффективный стек посреди торговли, — и это
  же защищает отложенное зачисление, не заставляя игрока сторожить тайминг.
  """

  use ExUnit.Case, async: true

  import BlockPoker.TablesHelpers

  alias BlockPoker.Tables.{RoomState, TableServer}

  setup do
    ensure_tables!()
    :ok
  end

  defp subscribe(room_id) do
    Phoenix.PubSub.subscribe(BlockPoker.PubSub, TableServer.topic(room_id))
  end

  defp room_in_hand do
    %{pid: pid, room_id: room_id} = start_room!(%{allowed_run_it_twice: false})
    seat!(pid, "user-1", 1, 500, :post)
    seat!(pid, "user-2", 2, 500, :post)
    :ok = TableServer.fire_timer(pid, :button_draw)

    assert TableServer.state(pid).phase == :hand
    %{pid: pid, room_id: room_id}
  end

  # Раздача заканчивается фолдом того, чей ход: банк уходит второму, стол
  # переходит к следующей раздаче.
  defp fold_hand(pid) do
    room = TableServer.state(pid)
    seat = Map.fetch!(room.seats, room.hand.to_act)
    :ok = TableServer.act(pid, seat.user_id, :fold, nil)

    # Пауза между раздачами таймерная: в тестах она прогоняется вручную.
    :ok = TableServer.fire_timer(pid, :next_hand)
  end

  defp queue!(pid, user_id, amount) do
    {:ok, ref, _replaced} = TableServer.begin_add_chips(pid, user_id, amount)
    TableServer.commit_add_chips(pid, user_id, ref)
  end

  test "докупка в раздаче не падает на стол, но объявляется столу" do
    %{pid: pid, room_id: room_id} = room_in_hand()
    :ok = subscribe(room_id)

    assert {:queued, seat, 300} = queue!(pid, "user-1", 300)
    assert RoomState.queued_add_chips(seat) == 300

    assert_receive {:table_event, "add_chips_queued", %{seat: 1, amount: 300}}
    refute_receive {:table_event, "chips_added", _payload}

    # Стек в торговле остался прежним: докупка не меняет уже сделанных ставок.
    room = TableServer.state(pid)
    assert RoomState.queued_add_chips(room.seats[1]) == 300
  end

  test "заявка превращается в фишки в начале следующей раздачи" do
    %{pid: pid, room_id: room_id} = room_in_hand()
    stack = TableServer.state(pid).seats[1].stack

    {:queued, _seat, 300} = queue!(pid, "user-1", 300)
    :ok = subscribe(room_id)
    fold_hand(pid)

    assert_receive {:table_event, "chips_added", %{seat: 1}}

    room = TableServer.state(pid)
    assert RoomState.queued_add_chips(room.seats[1]) == nil

    # Стек вырос на докупку; результат самой раздачи к ней не примешивается,
    # поэтому сравнение идёт по нижней границе.
    assert room.seats[1].stack >= stack + 300 - 500
  end

  test "отложенную докупку можно отменить до начала раздачи" do
    %{pid: pid, room_id: room_id} = room_in_hand()
    :ok = subscribe(room_id)

    {:queued, _seat, 300} = queue!(pid, "user-1", 300)

    assert {:ok, _ref, 300} = TableServer.cancel_add_chips(pid, "user-1")
    assert_receive {:table_event, "add_chips_cancelled", %{seat: 1}}
    assert {:error, :no_queued_add_chips} = TableServer.cancel_add_chips(pid, "user-1")

    fold_hand(pid)
    refute_receive {:table_event, "chips_added", _payload}
  end

  test "зачисленную докупку отменить нельзя — это уже уход из-за стола" do
    %{pid: pid} = start_room!(%{allowed_run_it_twice: false})
    seat!(pid, "user-1", 1, 500, :post)

    {:ok, ref, nil} = TableServer.begin_add_chips(pid, "user-1", 300)
    {:ok, seat} = TableServer.commit_add_chips(pid, "user-1", ref)

    assert seat.stack == 800
    assert {:error, :no_queued_add_chips} = TableServer.cancel_add_chips(pid, "user-1")
  end
end
