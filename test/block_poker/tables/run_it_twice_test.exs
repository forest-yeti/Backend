defmodule BlockPoker.Tables.RunItTwiceTest do
  @moduledoc """
  Предложение сыграть дважды за живым столом: окно ответа, его таймер и то,
  что видит подключившийся в середине.

  Правила самого согласия проверяются в ядре
  (`BlockPoker.Engine.RunItTwiceTest`); здесь — оркестрация: не подвисает ли
  стол, гасится ли таймер и переживает ли окно реконнект.
  """

  use ExUnit.Case, async: true

  import BlockPoker.TablesHelpers

  alias BlockPoker.Tables.TableServer
  alias Socket.Views.TableView

  setup do
    ensure_tables!()
    :ok
  end

  defp table(opts \\ []) do
    {clock, advance} = manual_clock()
    setting = Keyword.get(opts, :setting, %{})

    # Часы по умолчанию ручные; тестам снапшота нужны настоящие — остаток
    # окна view считает по монотонным часам системы, как в проде.
    opts = if opts[:clock] == :real, do: [], else: [clock: clock]

    %{pid: pid, room_id: room_id} = start_room!(setting, Keyword.merge([timers: :manual], opts))

    seat!(pid, "user-1", 1, 400)
    seat!(pid, "user-2", 2, 400)
    :ok = TableServer.fire_timer(pid, :button_draw)
    :ok = Phoenix.PubSub.subscribe(BlockPoker.PubSub, TableServer.topic(room_id))

    %{pid: pid, room_id: room_id, advance: advance}
  end

  # Оба в олл-ин на префлопе: торговля кончилась, борд пуст.
  defp all_in(pid) do
    room = TableServer.state(pid)
    first = Map.fetch!(room.seats, room.hand.to_act)
    :ok = TableServer.act(pid, first.user_id, :all_in, nil)

    room = TableServer.state(pid)
    second = Map.fetch!(room.seats, room.hand.to_act)
    :ok = TableServer.act(pid, second.user_id, :all_in, nil)
    pid
  end

  defp run_out(pid) do
    Enum.reduce_while(1..10, :ok, fn _step, _acc ->
      case TableServer.fire_timer(pid, :runout) do
        :ok -> {:cont, :ok}
        {:error, :no_such_timer} -> {:halt, :ok}
      end
    end)
  end

  describe "окно ответа" do
    test "предложение уходит в стол, борд ждёт ответа" do
      %{pid: pid} = table()
      all_in(pid)

      assert_received {:table_event, "all_in_showdown", _payload}
      assert_received {:table_event, "run_it_twice_offer", offer}
      assert offer.seats == [1, 2]

      # Пока идёт вопрос, доводка не тикает: тикает окно.
      room = TableServer.state(pid)
      assert room.hand.board == []
      assert room.rit_deadline_at != nil
      assert {:error, :no_such_timer} = TableServer.fire_timer(pid, :runout)
    end

    test "время вышло — играем один раз" do
      %{pid: pid} = table()
      all_in(pid)

      :ok = TableServer.fire_timer(pid, :rit)

      assert_received {:table_event, "run_it_twice_decided", %{accepted: false}}

      room = TableServer.state(pid)
      assert room.hand.board_2 == nil
      assert room.rit_deadline_at == nil
    end

    test "согласились оба — второй борд появляется, таймер окна гаснет" do
      %{pid: pid} = table()
      all_in(pid)

      assert :ok = TableServer.answer_run_it_twice(pid, "user-1", true)
      # Один ответ вопроса не закрывает: ждём второго.
      refute_received {:table_event, "run_it_twice_decided", _payload}

      assert :ok = TableServer.answer_run_it_twice(pid, "user-2", true)
      assert_received {:table_event, "run_it_twice_decided", %{accepted: true}}

      # Окно закрыто вместе с таймером — просроченный тик уже некому обслужить.
      assert {:error, :no_such_timer} = TableServer.fire_timer(pid, :rit)

      :ok = TableServer.fire_timer(pid, :runout)
      assert_received {:table_event, "street_dealt", %{street: :flop} = flop}

      assert length(flop.board) == 3
      assert length(flop.board_2) == 3
      assert flop.board != flop.board_2
    end

    test "отказ первого не ждёт второго" do
      %{pid: pid} = table()
      all_in(pid)

      assert :ok = TableServer.answer_run_it_twice(pid, "user-1", false)
      assert_received {:table_event, "run_it_twice_decided", %{accepted: false}}

      assert {:error, :run_it_twice_not_offered} =
               TableServer.answer_run_it_twice(pid, "user-2", true)
    end

    test "раздача доигрывается двумя бордами и раздаёт весь банк" do
      %{pid: pid} = table()
      all_in(pid)

      :ok = TableServer.answer_run_it_twice(pid, "user-1", true)
      :ok = TableServer.answer_run_it_twice(pid, "user-2", true)
      run_out(pid)

      assert_received {:table_event, "hand_finished", finished}
      assert [%{run: 1}, %{run: 2}] = finished.runs
      assert Enum.sum(Map.values(finished.payouts)) == 800

      room = TableServer.state(pid)
      assert Enum.sum(Enum.map(Map.values(room.seats), & &1.stack)) == 800
    end
  end

  describe "кто может отвечать" do
    test "наблюдатель получает отказ, стол не сдвигается" do
      %{pid: pid} = table()
      all_in(pid)

      assert {:error, :not_seated} = TableServer.answer_run_it_twice(pid, "stranger", true)
      assert TableServer.state(pid).hand.board == []
    end

    test "вопроса нет — отвечать нечего" do
      %{pid: pid} = table(setting: %{allowed_run_it_twice: false})
      all_in(pid)

      refute_received {:table_event, "run_it_twice_offer", _payload}

      assert {:error, :run_it_twice_not_offered} =
               TableServer.answer_run_it_twice(pid, "user-1", true)
    end
  end

  describe "снапшот" do
    test "вернувшийся внутри окна видит вопрос и остаток времени" do
      %{pid: pid} = table(clock: :real)
      all_in(pid)

      view = pid |> TableServer.state() |> TableView.render("user-1")

      assert %{seats: [1, 2], deadline_ms: remaining} = view.run_it_twice
      assert remaining > 0

      # Ответ после реконнекта принимается — окно то же самое.
      assert :ok = TableServer.answer_run_it_twice(pid, "user-1", true)
    end

    test "после решения вопроса в снапшоте нет" do
      %{pid: pid} = table(clock: :real)
      all_in(pid)

      :ok = TableServer.answer_run_it_twice(pid, "user-1", false)

      view = pid |> TableServer.state() |> TableView.render("user-1")
      assert view.run_it_twice == nil
    end
  end
end
