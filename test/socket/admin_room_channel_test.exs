defmodule Socket.Channels.Admin.RoomChannelTest do
  @moduledoc """
  Уровень 4: god-mode насквозь.

  Ключевая проверка — та, ради которой режим и изолирован: админ видит
  **обе** пары карманных карт, а снапшот каждого игрока по-прежнему не
  содержит чужих. Оба факта проверяются в одном сценарии, потому что
  порознь они ничего не доказывают.
  """

  use Socket.ChannelCase, async: false

  import Ecto.Query, only: [where: 3]

  import BlockPoker.AccountsFixtures
  import BlockPoker.AdminFixtures
  import BlockPoker.CashGamesFixtures
  import BlockPoker.TablesHelpers

  alias BlockPoker.CashGames.CashGameSetting
  alias BlockPoker.Tables.TableServer
  alias Ecto.Adapters.SQL.Sandbox
  alias Socket.{AdminSocket, UserSocket}

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

    session = admin_session_fixture()

    %{
      room_id: room_id,
      setting: setting,
      session: session,
      buy_in: CashGameSetting.min_buy_in_chips(setting)
    }
  end

  defp connect_player(room_id) do
    user = user_fixture()
    {:ok, %{token: token}} = BlockPoker.Accounts.start_session(user)
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    {:ok, snapshot, channel} = subscribe_and_join(socket, "table:#{room_id}", %{})

    %{user: user, channel: channel, snapshot: snapshot}
  end

  defp join_admin(session, room_id) do
    {:ok, socket} = connect(AdminSocket, %{"token" => session.access})
    subscribe_and_join(socket, "admin:room:#{room_id}", %{})
  end

  defp seat_players(room_id, buy_in) do
    first = connect_player(room_id)
    second = connect_player(room_id)

    ref = push(first.channel, "join_seat", %{"seat" => 1, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload

    ref = push(second.channel, "join_seat", %{"seat" => 2, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload

    {first, second}
  end

  # Раздача начинается с розыгрыша кнопки, и его таймер в тестах
  # прогоняется вручную: реальным временем таймеры стола не отсчитываются
  # (§11 CLAUDE.md).
  defp deal!(room_id) do
    :ok = TableServer.fire_timer(BlockPoker.Tables.TableRegistry.whereis(room_id), :button_draw)
    assert_push "hand_started", %{}
  end

  test "админ видит все карманные карты, а игроки — только свои", %{
    room_id: room_id,
    session: session,
    buy_in: buy_in
  } do
    {first, _second} = seat_players(room_id, buy_in)
    deal!(room_id)

    assert {:ok, %{room: room}, _channel} = join_admin(session, room_id)

    assert room.hand
    hole = room.hand.hole_cards

    assert map_size(hole) == 2
    assert Enum.all?(Map.values(hole), &(length(&1) == 2))

    # Остаток колоды — тоже отладочные данные, и они на месте.
    assert is_list(room.hand.deck)

    # А снапшот игрока по-прежнему без чужих карт: `TableView` не получил
    # никакого флага «я админ», и получить его не может.
    ref = push(first.channel, "table_state", %{})
    assert_reply ref, :ok, snapshot

    others = Enum.reject(snapshot.seats, &(&1.user_id == first.user.id))

    assert Enum.all?(others, &(not Map.has_key?(&1, :hole_cards)))
    refute Map.has_key?(snapshot, :hand) and Map.has_key?(snapshot.hand || %{}, :hole_cards)
  end

  test "отклонённое действие игрока приходит в ленту с кодом", %{
    room_id: room_id,
    session: session,
    buy_in: buy_in
  } do
    {first, second} = seat_players(room_id, buy_in)
    deal!(room_id)

    assert {:ok, _reply, _channel} = join_admin(session, room_id)

    # Ход не в свою очередь: один из двоих ходит первым, второй получит
    # отказ. Кто именно — решают правила, поэтому пробуются оба.
    push(first.channel, "action", %{"type" => "check"})
    push(second.channel, "action", %{"type" => "check"})

    assert_push "intent_result", %{outcome: "error", code: code}
    assert code in ["not_your_turn", "illegal_action", "stale_action"]
  end

  test "лента отдаётся при join: подключившийся в середине видит начало", %{
    room_id: room_id,
    session: session,
    buy_in: buy_in
  } do
    {_first, _second} = seat_players(room_id, buy_in)

    assert {:ok, %{feed: feed}, _channel} = join_admin(session, room_id)

    assert Enum.any?(feed, &(&1.event == "join_seat"))
  end

  test "канал наблюдения не принимает мутирующих сообщений", %{
    room_id: room_id,
    session: session,
    buy_in: buy_in
  } do
    {_first, _second} = seat_players(room_id, buy_in)

    assert {:ok, _reply, channel} = join_admin(session, room_id)

    ref = push(channel, "action", %{"type" => "fold"})
    assert_reply ref, :error, %{code: "illegal_action"}

    ref = push(channel, "join_seat", %{"seat" => 3, "buy_in" => buy_in})
    assert_reply ref, :error, %{code: "illegal_action"}
  end

  test "игровой токен не открывает админский сокет", %{room_id: _room_id} do
    user = user_fixture()
    {:ok, %{token: token}} = BlockPoker.Accounts.start_session(user)

    assert {:error, %{code: "token_invalid"}} = connect(AdminSocket, %{"token" => token})
  end

  test "админский сокет не открывает игровой", %{session: session} do
    assert {:error, %{code: "token_invalid"}} = connect(UserSocket, %{"token" => session.access})
  end

  test "отозванная сессия не пускает в наблюдение", %{room_id: room_id, session: session} do
    {:ok, socket} = connect(AdminSocket, %{"token" => session.access})
    :ok = BlockPoker.Admin.logout(session.session.id)

    assert {:error, %{code: "admin_session_expired"}} =
             subscribe_and_join(socket, "admin:room:#{room_id}", %{})
  end

  test "открытие и закрытие наблюдения попадают в журнал", %{
    room_id: room_id,
    session: session
  } do
    assert {:ok, _reply, channel} = join_admin(session, room_id)

    # Выход из канала — штатное завершение его процесса, и тест с ним
    # связан: без `unlink` он уносит и сам тест.
    Process.unlink(channel.channel_pid)
    ref = leave(channel)
    assert_reply ref, :ok

    actions =
      BlockPoker.Admin.AdminAudit
      |> where([a], a.subject_id == ^room_id)
      |> BlockPoker.Repo.all()
      |> Enum.map(& &1.action)
      |> Enum.sort()

    assert actions == [:observe_room_close, :observe_room_open]
  end
end
