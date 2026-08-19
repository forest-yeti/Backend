defmodule BlockPoker.Tables.ManualStartTest do
  @moduledoc """
  Ручной запуск стола: комната с `auto_start: false` сама не стартует, а
  команду на старт принимает только от администратора.
  """

  use ExUnit.Case, async: true

  import BlockPoker.TablesHelpers

  alias BlockPoker.Tables.{RoomState, TableServer}
  alias Socket.Views.TableView

  setup do
    ensure_tables!()
    :ok
  end

  describe "автостарт" do
    test "обычный стол стартует сам, как только собрались двое" do
      %{pid: pid} = start_room!()

      seat!(pid, "user-1", 1, 400)
      seat!(pid, "user-2", 2, 400)

      assert TableServer.state(pid).game_started?
    end

    test "стол без автостарта не стартует даже полным составом" do
      %{pid: pid} = start_room!(%{auto_start: false, max_players: 2})

      seat!(pid, "user-1", 1, 400)
      seat!(pid, "user-2", 2, 400)

      room = TableServer.state(pid)
      refute room.game_started?
      assert room.phase == :idle
    end
  end

  describe "команда start_game" do
    test "администратор запускает стол — идёт розыгрыш кнопки" do
      %{pid: pid} = start_room!(%{auto_start: false})

      seat_admin!(pid, "user-1", 1, 400)
      seat!(pid, "user-2", 2, 400)

      assert :ok = TableServer.start_game(pid, "user-1")

      room = TableServer.state(pid)
      assert room.game_started?
      assert room.phase == :button_draw
    end

    test "обычному игроку запуск недоступен" do
      %{pid: pid} = start_room!(%{auto_start: false})

      seat!(pid, "user-1", 1, 400)
      seat!(pid, "user-2", 2, 400)

      assert {:error, :start_not_available} = TableServer.start_game(pid, "user-1")
      refute TableServer.state(pid).game_started?
    end

    test "не сидящий за столом получает not_seated" do
      %{pid: pid} = start_room!(%{auto_start: false})

      seat_admin!(pid, "user-1", 1, 400)

      assert {:error, :not_seated} = TableServer.start_game(pid, "stranger")
    end

    test "в одиночку стол не запускается" do
      %{pid: pid} = start_room!(%{auto_start: false})

      seat_admin!(pid, "user-1", 1, 400)

      assert {:error, :start_not_available} = TableServer.start_game(pid, "user-1")
    end

    test "за столом с автостартом команда не нужна и не проходит" do
      %{pid: pid} = start_room!()

      seat_admin!(pid, "user-1", 1, 400)
      seat!(pid, "user-2", 2, 400)

      assert {:error, :start_not_available} = TableServer.start_game(pid, "user-1")
    end

    test "повторный запуск уже начатой игры отвергается" do
      %{pid: pid} = start_room!(%{auto_start: false})

      seat_admin!(pid, "user-1", 1, 400)
      seat!(pid, "user-2", 2, 400)

      assert :ok = TableServer.start_game(pid, "user-1")
      assert {:error, :start_not_available} = TableServer.start_game(pid, "user-1")
    end
  end

  describe "снапшот игрока" do
    test "флаг горит только у администратора и только пока стол ждёт запуска" do
      %{pid: pid} = start_room!(%{auto_start: false})

      seat_admin!(pid, "user-1", 1, 400)
      seat!(pid, "user-2", 2, 400)

      room = TableServer.state(pid)
      assert TableView.render(room, "user-1").you.can_start_manual
      refute TableView.render(room, "user-2").you.can_start_manual

      :ok = TableServer.start_game(pid, "user-1")
      refute TableView.render(TableServer.state(pid), "user-1").you.can_start_manual
    end

    test "за столом с автостартом флаг погашен и у администратора" do
      %{pid: pid} = start_room!()

      seat_admin!(pid, "user-1", 1, 400)

      refute TableView.render(TableServer.state(pid), "user-1").you.can_start_manual
    end

    test "роль игрока в снапшот не попадает — ни в свой, ни в чужой" do
      %{pid: pid} = start_room!(%{auto_start: false})

      seat_admin!(pid, "user-1", 1, 400)
      seat!(pid, "user-2", 2, 400)

      room = TableServer.state(pid)

      for viewer <- ["user-1", "user-2"] do
        payload = room |> TableView.render(viewer) |> Jason.encode!()

        refute payload =~ "role"
        refute payload =~ ~s("admin")
      end
    end
  end

  describe "правило в ядре" do
    test "право на запуск считает RoomState, а не транспорт" do
      %{pid: pid} = start_room!(%{auto_start: false})

      seat_admin!(pid, "user-1", 1, 400)
      seat!(pid, "user-2", 2, 400)

      room = TableServer.state(pid)

      assert RoomState.awaiting_manual_start?(room)
      assert RoomState.can_start_manual?(room, "user-1")
      refute RoomState.can_start_manual?(room, "user-2")
      refute RoomState.can_start_manual?(room, "stranger")
    end
  end
end
