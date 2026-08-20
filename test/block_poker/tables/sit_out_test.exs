defmodule BlockPoker.Tables.SitOutTest do
  @moduledoc """
  Пауза за столом: отложенность на время раздачи и срок, после которого
  место возвращается столу.

  Таймеры прогоняются вручную, часы инжектируются — ожиданий здесь нет
  (§11 CLAUDE.md).
  """

  use ExUnit.Case, async: true

  import BlockPoker.TablesHelpers

  alias BlockPoker.Tables.TableServer

  setup do
    ensure_tables!()
    :ok
  end

  defp subscribe(room_id) do
    Phoenix.PubSub.subscribe(BlockPoker.PubSub, TableServer.topic(room_id))
  end

  # Стол, у которого выселение не ходит в кошелёк, а сообщает тесту, кого
  # оно выселило: деньги проверяются уровнем 3, здесь проверяется решение.
  defp room_with_evict(overrides \\ %{}) do
    test = self()

    start_room!(overrides,
      evict: fn room_id, user_id -> send(test, {:evicted, room_id, user_id}) end
    )
  end

  defp play_hand_out(pid) do
    Enum.reduce_while(1..60, :playing, fn _step, _acc ->
      room = TableServer.state(pid)

      case room.hand do
        nil ->
          {:halt, :done}

        hand ->
          seat = Map.fetch!(room.seats, hand.to_act)
          player = Map.fetch!(hand.players, hand.to_act)
          action = if hand.bet == player.committed, do: :check, else: :call
          :ok = TableServer.act(pid, seat.user_id, action, nil)
          {:cont, :playing}
      end
    end)
  end

  describe "во время раздачи" do
    test "сит-аут откладывается: текущую раздачу игрок доигрывает" do
      %{pid: pid, room_id: room_id} = room_with_evict()
      seat!(pid, "user-1", 1, 400, :post)
      seat!(pid, "user-2", 2, 400, :post)
      :ok = TableServer.fire_timer(pid, :button_draw)
      :ok = subscribe(room_id)

      assert {:ok, %{pending: true}} = TableServer.sit_out(pid, "user-1")
      assert_receive {:table_event, "sit_out_pending", %{seat: 1}}

      seat = TableServer.state(pid).seats[1]
      assert seat.status == :playing
      assert seat.sit_out_pending
      assert TableServer.state(pid).hand.players[1] != nil
    end

    test "пауза начинается по концу раздачи" do
      %{pid: pid, room_id: room_id} = room_with_evict()
      seat!(pid, "user-1", 1, 400, :post)
      seat!(pid, "user-2", 2, 400, :post)
      :ok = TableServer.fire_timer(pid, :button_draw)
      {:ok, %{pending: true}} = TableServer.sit_out(pid, "user-1")
      :ok = subscribe(room_id)

      play_hand_out(pid)

      assert_receive {:table_event, "seat_sitting_out", %{seat: 1, reason: "sit_out"}}
      seat = TableServer.state(pid).seats[1]
      assert seat.status == :sitting_out
      refute seat.sit_out_pending
    end

    test "передумавший до конца раздачи остаётся играть" do
      %{pid: pid} = room_with_evict()
      seat!(pid, "user-1", 1, 400, :post)
      seat!(pid, "user-2", 2, 400, :post)
      :ok = TableServer.fire_timer(pid, :button_draw)

      {:ok, %{pending: true}} = TableServer.sit_out(pid, "user-1")
      assert :ok = TableServer.sit_in(pid, "user-1")

      play_hand_out(pid)

      seat = TableServer.state(pid).seats[1]
      assert seat.status == :playing
      refute seat.sit_out_pending
    end

    test "вне раздачи пауза начинается сразу" do
      %{pid: pid, room_id: room_id} = room_with_evict()
      seat!(pid, "user-1", 1, 400)
      :ok = subscribe(room_id)

      assert {:ok, %{pending: false}} = TableServer.sit_out(pid, "user-1")
      assert_receive {:table_event, "seat_sitting_out", %{seat: 1, reason: "sit_out"}}
      assert TableServer.state(pid).seats[1].status == :sitting_out
    end

    test "повторный сит-аут отвечает отказом, а не вторым таймером" do
      %{pid: pid} = room_with_evict()
      seat!(pid, "user-1", 1, 400)
      {:ok, %{pending: false}} = TableServer.sit_out(pid, "user-1")

      assert {:error, :already_sitting_out} = TableServer.sit_out(pid, "user-1")
    end
  end

  describe "срок паузы" do
    test "истёк — игрок уходит из-за стола" do
      %{pid: pid, room_id: room_id} = room_with_evict()
      seat!(pid, "user-1", 1, 400)
      {:ok, _} = TableServer.sit_out(pid, "user-1")
      :ok = subscribe(room_id)

      :ok = TableServer.fire_timer(pid, {:sit_out, 1})

      assert_receive {:table_event, "sit_out_expired", %{seat: 1, user_id: "user-1"}}
      assert_receive {:evicted, ^room_id, "user-1"}
    end

    test "возврат в игру снимает срок" do
      %{pid: pid} = room_with_evict()
      seat!(pid, "user-1", 1, 400)
      {:ok, _} = TableServer.sit_out(pid, "user-1")

      assert :ok = TableServer.sit_in(pid, "user-1")
      assert {:error, :no_such_timer} = TableServer.fire_timer(pid, {:sit_out, 1})
      assert TableServer.state(pid).seats[1].sit_out_until == nil
    end

    test "отсчёт виден в состоянии места" do
      {clock, _advance} = manual_clock(1_000)
      %{pid: pid, setting: setting} = start_room!(%{}, clock: clock)
      seat!(pid, "user-1", 1, 400)

      {:ok, _} = TableServer.sit_out(pid, "user-1")

      assert TableServer.state(pid).seats[1].sit_out_until ==
               1_000 + setting.sit_out_timeout_ms
    end

    test "истёкший grace держит место тем же сроком" do
      %{pid: pid, room_id: room_id} = room_with_evict()
      seat!(pid, "user-1", 1, 400)
      :ok = TableServer.disconnect(pid, "user-1")
      :ok = subscribe(room_id)

      :ok = TableServer.fire_timer(pid, {:grace, 1})
      assert_receive {:table_event, "seat_sitting_out", %{seat: 1, reason: "disconnected"}}
      assert TableServer.state(pid).seats[1].sit_out_until != nil

      :ok = TableServer.fire_timer(pid, {:sit_out, 1})
      assert_receive {:evicted, ^room_id, "user-1"}
    end
  end
end
