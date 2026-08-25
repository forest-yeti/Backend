defmodule Socket.Channels.Admin.GamesChannelTest do
  @moduledoc """
  Уровень 4: живой список игр по сокету.

  Проверяется то, ради чего список один: комната любого режима попадает
  в него без отдельной ручки, и открытие новой комнаты доезжает до
  подписчика само.
  """

  use Socket.ChannelCase, async: false

  import BlockPoker.AccountsFixtures
  import BlockPoker.AdminFixtures
  import BlockPoker.CashGamesFixtures
  import BlockPoker.TablesHelpers

  alias BlockPoker.CashGames.CashGameSetting
  alias BlockPoker.Tables.TableServer
  alias Ecto.Adapters.SQL.Sandbox
  alias Socket.AdminSocket

  setup do
    ensure_tables!()

    %{session: admin_session_fixture()}
  end

  defp open_room!(overrides \\ %{}) do
    setting = setting_fixture(Map.merge(%{currency: :play_money, max_players: 6}, overrides))
    room_id = Ecto.UUID.generate()

    pid =
      start_supervised!(
        {TableServer, [room_id: room_id, setting: setting, timers: :manual]},
        id: room_id
      )

    Sandbox.allow(BlockPoker.Repo, self(), pid)

    %{room_id: room_id, setting: setting, buy_in: CashGameSetting.min_buy_in_chips(setting)}
  end

  defp join_admin(session) do
    {:ok, socket} = connect(AdminSocket, %{"token" => session.access})
    subscribe_and_join(socket, "admin:games", %{})
  end

  test "живая комната видна в списке с составом игроков", %{session: session} do
    %{room_id: room_id, buy_in: buy_in} = open_room!()

    user = user_fixture()
    {:ok, %{token: token}} = BlockPoker.Accounts.start_session(user)
    {:ok, player_socket} = connect(Socket.UserSocket, %{"token" => token})
    {:ok, _snapshot, player} = subscribe_and_join(player_socket, "table:#{room_id}", %{})

    ref = push(player, "join_seat", %{"seat" => 1, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload

    assert {:ok, %{items: items}, _channel} = join_admin(session)

    room = Enum.find(items, &(&1.id == room_id))

    assert room.kind == :cash
    assert room.seats == 6
    assert room.players == 1
    assert [%{user_id: seated, seat: 1}] = room.participants
    assert seated == user.id
  end

  test "новая комната доезжает до подписчика сама", %{session: session} do
    assert {:ok, _reply, _channel} = join_admin(session)

    %{room_id: room_id, buy_in: buy_in} = open_room!()

    user = user_fixture()
    {:ok, %{token: token}} = BlockPoker.Accounts.start_session(user)
    {:ok, player_socket} = connect(Socket.UserSocket, %{"token" => token})
    {:ok, _snapshot, player} = subscribe_and_join(player_socket, "table:#{room_id}", %{})

    # Комната рассказывает о себе, когда меняется её состав: посадка —
    # ровно такое изменение.
    ref = push(player, "join_seat", %{"seat" => 2, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload

    assert_push "games", %{items: items}
    assert Enum.any?(items, &(&1.id == room_id))
  end

  test "фильтр по режиму отсекает чужие столы", %{session: session} do
    %{room_id: room_id} = open_room!()

    assert {:ok, _reply, channel} = join_admin(session)

    ref = push(channel, "list", %{"kind" => "mtt"})
    assert_reply ref, :ok, %{items: items}

    refute Enum.any?(items, &(&1.id == room_id))

    ref = push(channel, "list", %{"kind" => "cash"})
    assert_reply ref, :ok, %{items: cash}

    assert Enum.any?(cash, &(&1.id == room_id))
  end
end
