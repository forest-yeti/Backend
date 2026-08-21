defmodule BlockPoker.Tables.ShowCardsTest do
  @moduledoc """
  Добровольный показ карт за столом: окно после раздачи, выбор карт и то,
  почему во время раздачи показать нельзя.

  Главная проверка здесь — про честность игры: пока идёт торговля, карты
  игрока не уходят никому, чем бы он ни нажал.
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
    opts = if opts[:clock] == :real, do: [], else: [clock: clock]
    %{pid: pid, room_id: room_id} = start_room!(%{}, Keyword.merge([timers: :manual], opts))

    seat!(pid, "user-1", 1, 400)
    seat!(pid, "user-2", 2, 400)
    :ok = TableServer.fire_timer(pid, :button_draw)
    :ok = Phoenix.PubSub.subscribe(BlockPoker.PubSub, TableServer.topic(room_id))

    %{pid: pid, room_id: room_id, advance: advance}
  end

  # Фолд первого же ходящего: банк уезжает без вскрытия, и никто карт не
  # показывал — ровно тот случай, ради которого окно и существует.
  defp fold_hand(pid) do
    room = TableServer.state(pid)
    seat = Map.fetch!(room.seats, room.hand.to_act)
    :ok = TableServer.act(pid, seat.user_id, :fold, nil)
    seat.user_id
  end

  defp other(user_id), do: if(user_id == "user-1", do: "user-2", else: "user-1")

  describe "окно после раздачи" do
    test "победитель по фолдам открывает обе карты, и их видит весь стол" do
      %{pid: pid} = table()
      winner = other(fold_hand(pid))

      assert :ok = TableServer.show_cards(pid, winner)

      assert_received {:table_event, "cards_shown", payload}
      assert [%{}, %{}] = payload.cards
      assert payload.seat == TableServer.state(pid).reveal.users |> seat_of(winner)
    end

    test "сбросивший тоже вправе открыться" do
      %{pid: pid} = table()
      folder = fold_hand(pid)

      assert :ok = TableServer.show_cards(pid, folder)
      assert_received {:table_event, "cards_shown", _payload}
    end

    test "можно показать одну карту — вторая остаётся закрытой" do
      %{pid: pid} = table()
      winner = other(fold_hand(pid))

      assert :ok = TableServer.show_cards(pid, winner, [1])

      assert_received {:table_event, "cards_shown", payload}
      assert [nil, %{}] = payload.cards
    end

    test "вторая карта досылается отдельным событием, первая не закрывается" do
      %{pid: pid} = table()
      winner = other(fold_hand(pid))

      :ok = TableServer.show_cards(pid, winner, [0])
      assert_received {:table_event, "cards_shown", first}
      assert [%{}, nil] = first.cards

      assert :ok = TableServer.show_cards(pid, winner, [1])
      assert_received {:table_event, "cards_shown", second}
      assert [%{}, %{}] = second.cards
    end

    test "повтор того же показа ничего не рассылает" do
      %{pid: pid} = table()
      winner = other(fold_hand(pid))

      :ok = TableServer.show_cards(pid, winner)
      assert_received {:table_event, "cards_shown", _payload}

      assert {:error, :already_shown} = TableServer.show_cards(pid, winner)
      refute_received {:table_event, "cards_shown", _payload}
    end

    test "открытые карты живут в снапшоте — вошедший в паузу их видит" do
      %{pid: pid} = table(clock: :real)
      winner = other(fold_hand(pid))
      :ok = TableServer.show_cards(pid, winner)

      view = TableView.render(TableServer.state(pid), "stranger")

      assert [%{cards: [%{}, %{}]}] = view.revealed
    end
  end

  describe "когда нельзя" do
    test "во время раздачи показать карты нельзя" do
      %{pid: pid} = table()

      assert {:error, :hand_in_progress} = TableServer.show_cards(pid, "user-1")
      refute_received {:table_event, "cards_shown", _payload}
    end

    test "наблюдателю отказ" do
      %{pid: pid} = table()
      fold_hand(pid)

      assert {:error, :not_seated} = TableServer.show_cards(pid, "stranger")
    end

    test "окно закрывается вместе с паузой между раздачами" do
      %{pid: pid, advance: advance} = table()
      winner = other(fold_hand(pid))

      # Ровно @next_hand_ms из TableServer.
      advance.(5_000)

      assert {:error, :reveal_unavailable} = TableServer.show_cards(pid, winner)
    end

    test "следующая раздача стирает окно" do
      %{pid: pid} = table()
      winner = other(fold_hand(pid))
      :ok = TableServer.fire_timer(pid, :next_hand)

      assert TableServer.state(pid).reveal == nil
      assert {:error, :hand_in_progress} = TableServer.show_cards(pid, winner)
    end
  end

  defp seat_of(users, user_id) do
    {seat, _id} = Enum.find(users, fn {_seat, id} -> id == user_id end)
    seat
  end
end
