defmodule BlockPoker.History.TableHistoryTest do
  @moduledoc """
  Уровень 2: что стол отдаёт истории и чего это ему стоит.

  Главная проверка здесь — не содержимое отчёта, а **независимость стола
  от хранилища**: запись истории не имеет права задерживать раздачу ни при
  каком состоянии БД. Стол — один процесс, и всё, что выполняется в нём
  синхронно, двигает таймеры хода живых игроков.
  """

  use ExUnit.Case, async: true

  import BlockPoker.TablesHelpers

  alias BlockPoker.History.{Build, Report, Writer}
  alias BlockPoker.Tables.TableServer

  setup do
    ensure_tables!()
    :ok
  end

  describe "отчёт о раздаче" do
    test "стол отдаёт отчёт, из которого собираются строки холдема" do
      report = play_and_capture()

      assert %Report{} = report

      # Идентификатор заведён при старте раздачи: на нём держится
      # идемпотентность повторной задачи.
      assert {:ok, _uuid} = Ecto.UUID.cast(report.hand_id)
      assert report.game_mode == :cash
      assert report.big_blind > 0

      rows = Build.rows(report)

      assert rows.kind == :holdem
      assert length(rows.players) == 2

      # Вынужденные ставки — такие же строки лога: иначе реплей начинается
      # с необъяснимого банка.
      assert Enum.any?(rows.actions, &(&1.action == :post_blind))
      assert Enum.all?(rows.stats, &(&1.hands == 1))
    end

    test "лог действий идёт в том же порядке, что и события раздачи" do
      rows = play_and_capture() |> Build.rows()

      assert rows.actions |> Enum.map(& &1.seq) == Enum.to_list(1..length(rows.actions))
    end
  end

  describe "независимость стола от хранилища" do
    test "недоступное хранилище не задерживает следующую раздачу" do
      # Writer подменяется процессом, который на сообщения не отвечает
      # вовсе — это и есть «БД недоступна» с точки зрения стола. Если бы
      # связь была `call`, стол встал бы здесь навсегда.
      {:ok, stuck} = Agent.start_link(fn -> :stuck end)
      previous = Process.whereis(Writer)
      if previous, do: Process.unregister(Writer)
      Process.register(stuck, Writer)

      on_exit(fn ->
        if Process.whereis(Writer) == stuck, do: Process.unregister(Writer)
        if previous && Process.alive?(previous), do: Process.register(previous, Writer)
      end)

      %{pid: pid} = start_room!()
      seat!(pid, "user-1", 1, 400)
      seat!(pid, "user-2", 2, 400)
      :ok = TableServer.fire_timer(pid, :button_draw)

      # Две раздачи подряд при «недоступном» хранилище: стол обязан пройти
      # их обычным порядком, а не встать на записи первой.
      play_hand_out(pid)
      assert TableServer.state(pid).hand == nil

      :ok = TableServer.fire_timer(pid, :next_hand)
      assert TableServer.state(pid).phase == :hand

      play_hand_out(pid)
      assert TableServer.state(pid).hand == nil
    end
  end

  # Раздача с двумя игроками, доигранная до конца. Отчёт перехватывается
  # подменой Writer на тест-процесс: проверяется ровно то, что стол наружу
  # отдаёт, а не то, что доедет до БД.
  defp play_and_capture do
    previous = Process.whereis(Writer)
    if previous, do: Process.unregister(Writer)
    Process.register(self(), Writer)

    on_exit(fn ->
      if Process.whereis(Writer) == self(), do: Process.unregister(Writer)
      if previous && Process.alive?(previous), do: Process.register(previous, Writer)
    end)

    %{pid: pid} = start_room!()
    seat!(pid, "user-1", 1, 400)
    seat!(pid, "user-2", 2, 400)
    :ok = TableServer.fire_timer(pid, :button_draw)
    play_hand_out(pid)

    assert_receive {:"$gen_cast", {:hand, report}}
    report
  end

  # Раздача доигрывается чеками и коллами: содержимое решений тесту
  # безразлично, важен только факт её завершения.
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
