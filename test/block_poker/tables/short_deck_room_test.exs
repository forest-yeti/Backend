defmodule BlockPoker.Tables.ShortDeckRoomTest do
  @moduledoc """
  Комната Short Deck: анте-стол поднимается из шаблона без блайндов, а вход
  в игру на нём происходит без ожидания.

  Про сами ставки — тесты уровня 1; здесь проверяется, что комната отдаёт
  структуре то, что та ждёт, и не тащит блайндовые правила на анте-стол.
  """

  use ExUnit.Case, async: true

  import BlockPoker.TablesHelpers

  alias BlockPoker.CashGames.CashGameSetting
  alias BlockPoker.Engine.Card
  alias BlockPoker.Tables.{RoomState, TableServer}
  alias Socket.Views.TableView

  @ante 10

  setup do
    ensure_tables!()
    :ok
  end

  defp short_deck_room!(overrides \\ %{}) do
    start_room!(
      Map.merge(
        %{game_type: :short_deck, small_blind: 0, big_blind: 0, ante: @ante, max_players: 6},
        overrides
      )
    )
  end

  describe "стол" do
    test "поднимается из шаблона без блайндов" do
      %{pid: pid} = short_deck_room!()

      room = TableServer.state(pid)

      assert room.setting.game_type == :short_deck
      assert RoomState.bet_unit(room) == @ante
    end

    test "бай-ин считается в анте, а не в больших блайндах" do
      %{pid: pid, setting: setting} = short_deck_room!(%{min_buy_in: 40, max_buy_in: 100})

      room = TableServer.state(pid)

      # Сорок анте — можно, тридцать девять и сто один — нет.
      assert :ok = RoomState.validate_buy_in(room, 40 * @ante)
      assert {:error, :invalid_buy_in} = RoomState.validate_buy_in(room, 39 * @ante)
      assert {:error, :invalid_buy_in} = RoomState.validate_buy_in(room, 101 * @ante)

      assert CashGameSetting.min_buy_in_chips(setting) == 40 * @ante
    end
  end

  describe "вход в игру" do
    test "севший играет ближайшую раздачу и блайнда не ждёт" do
      %{pid: pid} = short_deck_room!()

      seat!(pid, "user-1", 1, 40 * @ante)
      seat!(pid, "user-2", 2, 40 * @ante)

      # Третий садится, когда игра уже идёт: на блайндовом столе он ждал бы
      # своего большого блайнда.
      third = seat!(pid, "user-3", 3, 40 * @ante)

      refute third.waiting_for_bb
      refute third.post_required
      refute third.can_post
      assert third.status == :playing
    end

    test "вход за взнос на анте-столе недоступен" do
      %{pid: pid} = short_deck_room!()

      seat!(pid, "user-1", 1, 40 * @ante)
      seat!(pid, "user-2", 2, 40 * @ante)
      seat!(pid, "user-3", 3, 40 * @ante)

      assert {:error, :post_not_available} = TableServer.request_post(pid, "user-3", true)
    end

    test "снапшот отдаёт номинал стола и структуру ставок" do
      %{pid: pid} = short_deck_room!()
      seat!(pid, "user-1", 1, 40 * @ante)

      snapshot = pid |> TableServer.state() |> TableView.render("user-1")

      assert snapshot.game_type == :short_deck
      assert snapshot.betting_structure == :button_ante
      assert snapshot.bet_unit == @ante
      assert snapshot.small_blind == 0
      assert snapshot.big_blind == 0
      assert snapshot.ante == @ante
    end
  end

  describe "раздача" do
    test "стол начинает игру и раздаёт анте-раздачу" do
      %{pid: pid, room_id: room_id} = short_deck_room!()
      Phoenix.PubSub.subscribe(BlockPoker.PubSub, TableServer.topic(room_id))

      seat!(pid, "user-1", 1, 40 * @ante)
      seat!(pid, "user-2", 2, 40 * @ante)

      # Розыгрыш кнопки — та же процедура, что и на блайндовом столе.
      assert_receive {:table_event, "button_draw", _payload}
      :ok = TableServer.fire_timer(pid, :button_draw)

      room = TableServer.state(pid)

      assert room.phase == :hand
      assert room.hand.bet_unit == @ante

      # Банк до первой карты: анте с каждого плюс второе анте кнопки.
      assert room.hand.pot == 3 * @ante
    end

    test "карт младше шестёрки за столом не бывает" do
      %{pid: pid} = short_deck_room!()

      seat!(pid, "user-1", 1, 40 * @ante)
      seat!(pid, "user-2", 2, 40 * @ante)
      :ok = TableServer.fire_timer(pid, :button_draw)

      hand = TableServer.state(pid).hand
      dealt = Enum.flat_map(hand.players, fn {_seat, player} -> player.hole end) ++ hand.deck

      assert Enum.all?(dealt, &(Card.rank(&1) >= 4))
    end
  end
end
