defmodule BlockPoker.Tables.RebuyTest do
  @moduledoc """
  Нулевой стек: окно на докупку и то, чем оно кончается.

  Проигравший всё не встаёт молча — стол даёт ему время докупиться. Но и
  держать кресло за игроком без фишек бесконечно нельзя: истёкшее окно
  возвращает место столу.
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

  # Стол, у которого уход не ходит в кошелёк, а сообщает тесту, кого он
  # выселил: деньги проверяются уровнем 3, здесь — решение комнаты.
  defp room_with_evict do
    test = self()

    start_room!(%{allowed_run_it_twice: false},
      evict: fn room_id, user_id -> send(test, {:evicted, room_id, user_id}) end
    )
  end

  # Короткий стек идёт ва-банк, большой платит: к концу раздачи один из
  # двоих обязательно окажется с нулевым стеком.
  defp bust_someone(pid) do
    room = TableServer.state(pid)
    short = Map.fetch!(room.seats, room.hand.to_act)
    :ok = TableServer.act(pid, short.user_id, :all_in, nil)

    room = TableServer.state(pid)
    caller = Map.fetch!(room.seats, room.hand.to_act)
    :ok = TableServer.act(pid, caller.user_id, :call, nil)

    # Доводка борта идёт по улице за тик — прогоняем её вручную.
    Enum.reduce_while(1..10, :running, fn _step, _acc ->
      case TableServer.state(pid).hand do
        nil -> {:halt, :done}
        _hand -> {:cont, TableServer.fire_timer(pid, :runout)}
      end
    end)

    TableServer.state(pid)
    |> Map.fetch!(:seats)
    |> Map.values()
    |> Enum.find(&(&1.user_id != nil and &1.stack == 0))
  end

  defp busted_room do
    %{pid: pid, room_id: room_id} = room_with_evict()
    seat!(pid, "user-1", 1, 400, :post)
    seat!(pid, "user-2", 2, 1000, :post)
    :ok = TableServer.fire_timer(pid, :button_draw)

    broke = bust_someone(pid)
    assert broke != nil, "раздача ва-банк обязана оставить кого-то без фишек"
    assert broke.status == :sitting_out

    %{pid: pid, room_id: room_id, broke: broke}
  end

  test "проигравший всё уходит в sitting_out и получает окно на докупку" do
    %{pid: pid, broke: broke} = busted_room()

    assert TableServer.state(pid).seats[broke.number].user_id == broke.user_id
    assert :ok = TableServer.fire_timer(pid, {:rebuy, broke.number})
  end

  test "окно истекло — место возвращается столу" do
    %{pid: pid, room_id: room_id, broke: broke} = busted_room()
    :ok = subscribe(room_id)

    :ok = TableServer.fire_timer(pid, {:rebuy, broke.number})

    user_id = broke.user_id
    assert_receive {:table_event, "rebuy_expired", %{seat: seat, user_id: ^user_id}}
    assert seat == broke.number
    assert_receive {:evicted, ^room_id, ^user_id}
  end

  test "докупка в окне снимает таймер" do
    %{pid: pid, broke: broke} = busted_room()

    {:ok, ref, nil} = TableServer.begin_add_chips(pid, broke.user_id, 400)
    {:ok, seat} = TableServer.commit_add_chips(pid, broke.user_id, ref)

    assert seat.stack == 400
    assert seat.status == :playing
    assert {:error, :no_such_timer} = TableServer.fire_timer(pid, {:rebuy, broke.number})
  end
end
