defmodule BlockPoker.Tables.RabbitHuntingTest do
  @moduledoc """
  Rabbit hunting за столом: кто видит карты, как долго доступна кнопка и
  почему их нельзя получить, пока идёт раздача.

  Проверки здесь в основном про безопасность: показ обязан быть закрыт
  везде, кроме паузы после раздачи, законченной фолдом, и обязан обходить
  наблюдателя стороной.
  """

  use ExUnit.Case, async: true

  import BlockPoker.TablesHelpers

  alias BlockPoker.Tables.TableServer
  alias Socket.Views.TableView

  setup do
    ensure_tables!()
    :ok
  end

  # Стол на двоих с ручными часами: окно показа истекает по команде, а не
  # по реальному времени (§11 CLAUDE.md).
  defp table(opts \\ []) do
    {clock, advance} = manual_clock()

    # Часы по умолчанию ручные. Тестам снапшота нужны настоящие: view
    # считает остаток окна по монотонным часам системы, как в проде.
    opts = if opts[:clock] == :real, do: [], else: [clock: clock]
    %{pid: pid, room_id: room_id} = start_room!(%{}, Keyword.merge([timers: :manual], opts))

    seat!(pid, "user-1", 1, 400)
    seat!(pid, "user-2", 2, 400)
    :ok = TableServer.fire_timer(pid, :button_draw)
    :ok = Phoenix.PubSub.subscribe(BlockPoker.PubSub, TableServer.topic(room_id))

    %{pid: pid, room_id: room_id, advance: advance}
  end

  # Фолд первого же ходящего: раздача кончается без вскрытия на префлопе.
  defp fold_hand(pid) do
    room = TableServer.state(pid)
    seat = Map.fetch!(room.seats, room.hand.to_act)
    :ok = TableServer.act(pid, seat.user_id, :fold, nil)
  end

  describe "показ" do
    test "карты уходят каждому сидящему адресно, а не в общий топик" do
      %{pid: pid} = table()
      fold_hand(pid)

      assert :ok = TableServer.rabbit_hunt(pid, "user-1")

      assert_received {:table_private, "user-1", "rabbit_cards", payload}
      assert_received {:table_private, "user-2", "rabbit_cards", ^payload}
      refute_received {:table_event, "rabbit_cards", _payload}

      assert [%{street: :flop}, %{street: :turn}, %{street: :river}] = payload.streets
    end

    test "повторный запрос отдаёт те же карты и только запросившему" do
      %{pid: pid} = table()
      fold_hand(pid)

      :ok = TableServer.rabbit_hunt(pid, "user-1")
      assert_received {:table_private, "user-1", "rabbit_cards", first}
      assert_received {:table_private, "user-2", "rabbit_cards", _payload}

      assert :ok = TableServer.rabbit_hunt(pid, "user-2")
      assert_received {:table_private, "user-2", "rabbit_cards", ^first}
      refute_received {:table_private, "user-1", "rabbit_cards", _payload}
    end
  end

  describe "когда нельзя" do
    test "наблюдатель не видит карт и получает отказ" do
      %{pid: pid} = table()
      fold_hand(pid)

      assert {:error, :not_seated} = TableServer.rabbit_hunt(pid, "stranger")
      refute_received {:table_private, "stranger", "rabbit_cards", _payload}
    end

    test "во время раздачи — отказ" do
      %{pid: pid} = table()

      assert {:error, :rabbit_unavailable} = TableServer.rabbit_hunt(pid, "user-1")
    end

    test "после вскрытия снимка нет" do
      %{pid: pid} = table()
      play_to_showdown(pid)

      assert TableServer.state(pid).rabbit == nil
      assert {:error, :rabbit_unavailable} = TableServer.rabbit_hunt(pid, "user-1")
    end

    test "окно истекает вместе с паузой между раздачами" do
      %{pid: pid, advance: advance} = table()
      fold_hand(pid)

      advance.(2_500)

      assert {:error, :rabbit_unavailable} = TableServer.rabbit_hunt(pid, "user-1")
    end

    test "следующая раздача стирает снимок" do
      %{pid: pid} = table()
      fold_hand(pid)
      :ok = TableServer.fire_timer(pid, :next_hand)

      assert TableServer.state(pid).rabbit == nil
      assert {:error, :rabbit_unavailable} = TableServer.rabbit_hunt(pid, "user-1")
    end
  end

  describe "снапшот" do
    test "сидящему приходит доступность, после показа — карты" do
      %{pid: pid} = table(clock: :real)
      fold_hand(pid)

      you = TableView.render(TableServer.state(pid), "user-1").you
      assert you.rabbit.available
      assert you.rabbit.cards == nil

      :ok = TableServer.rabbit_hunt(pid, "user-1")

      you = TableView.render(TableServer.state(pid), "user-1").you
      refute you.rabbit.available
      assert [%{street: :flop} | _rest] = you.rabbit.cards
    end

    test "наблюдателю поля нет вовсе" do
      %{pid: pid} = table(clock: :real)
      fold_hand(pid)
      :ok = TableServer.rabbit_hunt(pid, "user-1")

      snapshot = TableView.render(TableServer.state(pid), "stranger")

      refute Map.has_key?(snapshot.you, :rabbit)
      refute snapshot |> inspect(limit: :infinity) |> String.contains?("street")
    end
  end

  # Доводит раздачу до вскрытия: оба чекают до конца.
  defp play_to_showdown(pid) do
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
