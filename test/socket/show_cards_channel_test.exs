defmodule Socket.Channels.ShowCardsChannelTest do
  @moduledoc """
  Показ карт глазами клиента: путь целиком, от payload до пуша.

  Написан по жалобе «нажимаешь одну карту — показываются обе». Проверяется
  именно то, что уходит в сокет соседу: закрытая карта обязана приехать
  к нему как `null`, а не как карта.
  """

  use Socket.ChannelCase, async: false

  import BlockPoker.AccountsFixtures
  import BlockPoker.CashGamesFixtures
  import BlockPoker.TablesHelpers

  alias BlockPoker.CashGames.CashGameSetting
  alias BlockPoker.Tables.TableServer
  alias Ecto.Adapters.SQL.Sandbox
  alias Socket.UserSocket

  setup do
    ensure_tables!()
    setting = setting_fixture(%{currency: :play_money, max_players: 6})
    room_id = Ecto.UUID.generate()

    pid =
      start_supervised!(
        {TableServer, [room_id: room_id, setting: setting, timers: :manual]},
        id: room_id
      )

    Sandbox.allow(BlockPoker.Repo, self(), pid)
    %{room_id: room_id, pid: pid, buy_in: CashGameSetting.min_buy_in_chips(setting)}
  end

  defp connect_player(room_id) do
    user = user_fixture()
    {:ok, %{token: token}} = BlockPoker.Accounts.start_session(user)
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    {:ok, _reply, channel} = subscribe_and_join(socket, "table:#{room_id}", %{})
    %{user: user, channel: channel}
  end

  # Стол на двоих, раздача заканчивается фолдом: карт никто не показывал,
  # и окно показа открыто у обоих.
  defp folded_hand(%{room_id: room_id, pid: pid, buy_in: buy_in}) do
    %{user: first, channel: first_channel} = connect_player(room_id)
    %{user: second, channel: second_channel} = connect_player(room_id)

    ref = push(first_channel, "join_seat", %{"seat" => 1, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload
    ref = push(second_channel, "join_seat", %{"seat" => 2, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload

    :ok = TableServer.fire_timer(pid, :button_draw)

    room = TableServer.state(pid)
    to_act = Map.fetch!(room.seats, room.hand.to_act).user_id

    {folder, winner} =
      if to_act == first.id,
        do: {first_channel, second_channel},
        else: {second_channel, first_channel}

    ref = push(folder, "action", %{"type" => "fold"})
    assert_reply ref, :ok, _payload

    %{winner: winner, folder: folder}
  end

  test "показана одна карта — соседу уезжает одна, вторая закрыта", context do
    %{winner: winner, folder: folder} = folded_hand(context)

    ref = push(winner, "show_cards", %{"cards" => [1]})
    assert_reply ref, :ok, _payload

    assert_push "cards_shown", %{cards: cards}
    assert [nil, %{rank: _, suit: _}] = cards

    # И у соседа в снапшоте ровно то же: открытая карта одна.
    ref = push(folder, "table_state", %{})
    assert_reply ref, :ok, snapshot
    assert [%{cards: [nil, %{}]}] = snapshot.revealed
  end

  test "без поля cards открываются обе", context do
    %{winner: winner} = folded_hand(context)

    ref = push(winner, "show_cards", %{})
    assert_reply ref, :ok, _payload

    assert_push "cards_shown", %{cards: [%{}, %{}]}
  end
end
