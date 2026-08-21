defmodule BlockPoker.Tables.BombPotTest do
  @moduledoc """
  Бомб-пот за столом: бросок до карт, раздача с флопа и то, чего в такой
  раздаче не происходит — страддла и платы за вход.
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

  defp started_room(overrides) do
    %{pid: pid, room_id: room_id} = start_room!(overrides)
    seat!(pid, "user-1", 1, 1_000, :post)
    seat!(pid, "user-2", 2, 1_000, :post)
    seat!(pid, "user-3", 3, 1_000, :post)
    %{pid: pid, room_id: room_id}
  end

  defp deal!(pid), do: :ok = TableServer.fire_timer(pid, :button_draw)

  describe "стопроцентный шанс" do
    test "стол объявляет бомб-пот и раздаёт сразу флоп" do
      %{pid: pid, room_id: room_id} = started_room(%{bomb_pot_chance: 10_000, bomb_pot_ante: 2})
      :ok = subscribe(room_id)

      deal!(pid)

      assert_receive {:table_event, "bomb_pot", %{ante: 20}}
      assert_receive {:table_event, "hand_started", %{bomb_pot: %{ante: 20}}}

      room = TableServer.state(pid)

      assert room.hand.street == :flop
      assert length(room.hand.board) == 3
      assert room.hand.pot == 60
      assert room.hand.bomb_pot == %{ante: 20}

      # Взнос платят все и поровну; блайндов в раздаче нет.
      assert Enum.map(1..3, &room.hand.players[&1].total) == [20, 20, 20]
    end

    test "окно страддла не открывается" do
      %{pid: pid, room_id: room_id} = started_room(%{bomb_pot_chance: 10_000})
      {:ok, _seat} = TableServer.straddle(pid, "user-1", 200)
      :ok = subscribe(room_id)

      deal!(pid)

      refute_receive {:table_event, "straddle_offer", _payload}

      room = TableServer.state(pid)
      assert room.phase == :hand

      # Объявление не снимается: оно сработает на ближайшей обычной раздаче.
      assert Map.fetch!(room.seats, 1).straddle == 200
    end
  end

  describe "выключенный бомб-пот" do
    test "раздача идёт с префлопа и ничего не объявляется" do
      %{pid: pid, room_id: room_id} = started_room(%{bomb_pot_chance: 0})
      :ok = subscribe(room_id)

      deal!(pid)

      refute_receive {:table_event, "bomb_pot", _payload}

      room = TableServer.state(pid)
      assert room.hand.street == :preflop
      assert room.hand.bomb_pot == nil
    end
  end
end
