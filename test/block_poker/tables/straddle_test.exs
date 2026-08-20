defmodule BlockPoker.Tables.StraddleTest do
  @moduledoc """
  Страддл за столом: объявление, окно на сумму и то, как одна заявка из
  нескольких доезжает до раздачи.

  Окно прогоняется вручную (`fire_timer/2`) — ожиданий здесь нет
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

  # Стол на трёх игроках с разыгранной кнопкой и остановленной перед самой
  # раздачей игрой: дальше раздачу запускает тест.
  defp started_room(overrides \\ %{}, buy_in \\ 1_000) do
    %{pid: pid, room_id: room_id, setting: setting} = start_room!(overrides)
    seat!(pid, "user-1", 1, buy_in, :post)
    seat!(pid, "user-2", 2, buy_in, :post)
    seat!(pid, "user-3", 3, buy_in, :post)
    %{pid: pid, room_id: room_id, setting: setting}
  end

  defp deal!(pid) do
    :ok = TableServer.fire_timer(pid, :button_draw)
  end

  describe "объявление" do
    test "сумма принимается и становится публичной" do
      %{pid: pid, room_id: room_id} = started_room()
      :ok = subscribe(room_id)

      assert {:ok, %{straddle: 200}} = TableServer.straddle(pid, "user-1", 200)
      assert_receive {:table_event, "straddle_mode", %{seat: 1, straddle: 200}}

      room = TableServer.state(pid)
      assert Map.fetch!(room.seats, 1).straddle == 200
    end

    test "меньше двух больших блайндов не принимается" do
      %{pid: pid} = started_room(%{small_blind: 50, big_blind: 100}, 10_000)

      assert {:error, :invalid_straddle} = TableServer.straddle(pid, "user-1", 199)
      assert {:ok, %{straddle: 200}} = TableServer.straddle(pid, "user-1", 200)
    end

    test "заявка сверх стека превращается в олл-ин вслепую" do
      %{pid: pid} = started_room()

      assert {:ok, %{straddle: 1_000}} = TableServer.straddle(pid, "user-1", 99_999)
    end

    test "короткий стек объявляет олл-ин вслепую ниже минимума" do
      # Стол с низким порогом входа: у места 3 всего 15 фишек при блайнде 10,
      # то есть на два номинала не хватает. Поставить вслепую всё, что есть,
      # он всё равно вправе — а выбрать сумму ниже минимума нет.
      %{pid: pid} = start_room!(%{min_buy_in: 1})
      seat!(pid, "user-1", 1, 1_000, :post)
      seat!(pid, "user-2", 2, 1_000, :post)
      seat!(pid, "user-3", 3, 15, :post)

      assert {:ok, %{straddle: 15}} = TableServer.straddle(pid, "user-3", 15)
      assert {:ok, %{straddle: 15}} = TableServer.straddle(pid, "user-3", 900)
      assert {:error, :invalid_straddle} = TableServer.straddle(pid, "user-3", 12)
    end

    test "`nil` снимает объявление" do
      %{pid: pid} = started_room()
      {:ok, _} = TableServer.straddle(pid, "user-1", 200)

      assert {:ok, %{straddle: nil}} = TableServer.straddle(pid, "user-1", nil)
      assert TableServer.state(pid).seats[1].straddle == nil
    end

    test "наблюдателю объявлять нечего" do
      %{pid: pid} = started_room()

      assert {:error, :not_seated} = TableServer.straddle(pid, "кто-то посторонний", 200)
    end
  end

  describe "окно перед раздачей" do
    test "объявивших нет — раздача начинается без задержки" do
      %{pid: pid, room_id: room_id} = started_room()
      :ok = subscribe(room_id)

      deal!(pid)

      assert TableServer.state(pid).phase == :hand
      refute_receive {:table_event, "straddle_offer", _payload}
    end

    test "объявивший есть — стол ждёт окно и только потом раздаёт" do
      %{pid: pid, room_id: room_id} = started_room()
      {:ok, _} = TableServer.straddle(pid, "user-1", 200)
      :ok = subscribe(room_id)

      deal!(pid)

      assert TableServer.state(pid).phase == :straddle
      assert TableServer.state(pid).hand == nil

      assert_receive {:table_event, "straddle_offer",
                      %{seats: [%{seat: 1, amount: 200}], min: 20}}

      :ok = TableServer.fire_timer(pid, :straddle)

      room = TableServer.state(pid)
      assert room.phase == :hand
      assert Map.fetch!(room.hand.players, 1).committed == 200
      assert room.hand.bet == 200
    end

    test "внутри окна сумму ещё можно поменять" do
      %{pid: pid} = started_room()
      {:ok, _} = TableServer.straddle(pid, "user-1", 200)
      deal!(pid)

      {:ok, _} = TableServer.straddle(pid, "user-1", 500)
      :ok = TableServer.fire_timer(pid, :straddle)

      assert TableServer.state(pid).hand.bet == 500
    end

    test "передумавший внутри окна раздаётся без страддла" do
      %{pid: pid} = started_room()
      {:ok, _} = TableServer.straddle(pid, "user-1", 200)
      deal!(pid)

      {:ok, _} = TableServer.straddle(pid, "user-1", nil)
      :ok = TableServer.fire_timer(pid, :straddle)

      assert TableServer.state(pid).hand.bet == 10
    end

    test "объявление держится и на следующую раздачу" do
      %{pid: pid} = started_room()
      {:ok, _} = TableServer.straddle(pid, "user-1", 200)
      deal!(pid)
      :ok = TableServer.fire_timer(pid, :straddle)

      # Молчание в окне — согласие на объявленную сумму, а не отказ:
      # галочка постоянная.
      assert TableServer.state(pid).seats[1].straddle == 200
    end

    test "заявок несколько — страддлит наибольшая" do
      %{pid: pid} = started_room()
      {:ok, _} = TableServer.straddle(pid, "user-1", 200)
      {:ok, _} = TableServer.straddle(pid, "user-3", 600)
      deal!(pid)
      :ok = TableServer.fire_timer(pid, :straddle)

      room = TableServer.state(pid)
      assert room.hand.bet == 600
      assert Map.fetch!(room.hand.players, 3).committed == 600

      # Проигравшая заявка деньгами не облагается: страддл в раздаче один.
      assert Map.fetch!(room.hand.players, 1).committed in [0, 10, 20]
    end
  end
end
