defmodule BlockPoker.Tables.ArtificialDisciplineTest do
  @moduledoc """
  Проверка шва `Engine.Discipline`: стол обязан провести раздачу дисциплины,
  про которую не знает ничего.

  Тест намеренно не про покер. `Discipline.Artificial` — круг передачи фишки
  без улиц, борда, банка, карманных карт и фолда; если `TableServer` её
  доигрывает, значит допущения холдема из оболочки действительно ушли.
  Провалившийся тест чинится в оболочке, а не здесь.
  """

  use ExUnit.Case, async: true

  import BlockPoker.TablesHelpers

  alias BlockPoker.Engine.Discipline.Artificial
  alias BlockPoker.Tables.{RoomState, TableServer}

  setup do
    ensure_tables!()
    :ok
  end

  defp start_artificial!(opts \\ []) do
    start_room!(%{}, Keyword.put(opts, :discipline, Artificial))
  end

  defp deal!(pid) do
    seat!(pid, "user-1", 1, 400, :post)
    seat!(pid, "user-2", 2, 400, :post)

    # Розыгрыш кнопки — механика стола, а не дисциплины: он одинаков для всех.
    TableServer.fire_timer(pid, :button_draw)
    TableServer.state(pid)
  end

  test "стол доводит раздачу чужой дисциплины до конца" do
    %{pid: pid} = start_artificial!()
    room = deal!(pid)

    assert room.phase == :hand
    assert Artificial.to_act(room.hand) == 1

    :ok = TableServer.act(pid, "user-1", :pass, room.action_seq)
    :ok = TableServer.act(pid, "user-2", :pass, nil)

    room = TableServer.state(pid)

    # Раздача кончилась, и стол перешёл к паузе тем же кодом, что и в холдеме.
    assert room.hand == nil
    assert room.hands_played == 1
  end

  test "фишки за столом не появляются и не исчезают" do
    %{pid: pid} = start_artificial!()
    room = deal!(pid)
    before = total_stacks(room)

    :ok = TableServer.act(pid, "user-1", :pass, nil)
    :ok = TableServer.act(pid, "user-2", :pass, nil)

    assert total_stacks(TableServer.state(pid)) == before
  end

  test "тайм-аут хода доигрывает за игрока средствами самой дисциплины" do
    %{pid: pid} = start_artificial!()
    deal!(pid)

    # По два тика на игрока: первый включает личный запас времени, второй
    # его дожигает и ходит за игрока. Это механика стола, общая для всех
    # дисциплин, — чем именно ходить, решает дисциплина.
    Enum.each(1..4, fn _tick -> TableServer.fire_timer(pid, :action) end)

    room = TableServer.state(pid)
    assert room.hand == nil
    assert room.hands_played == 1
  end

  test "снапшот собирается из того, что отдала дисциплина" do
    %{pid: pid} = start_artificial!()
    room = deal!(pid)

    snapshot = Socket.Views.TableView.render(room, "user-1")

    # Поля холдема стол не досочиняет: их в снапшоте просто нет.
    refute Map.has_key?(snapshot.hand, :board)
    refute Map.has_key?(snapshot.hand, :pot)
    assert snapshot.hand.to_act == 1
    assert snapshot.you.legal_actions == %{pass: true}

    # Механик, которых у дисциплины нет, стол не выдумывает.
    assert snapshot.run_it_twice == nil
    assert snapshot.revealed == []
  end

  defp total_stacks(room) do
    room |> RoomState.seats() |> Enum.map(& &1.stack) |> Enum.sum()
  end
end
