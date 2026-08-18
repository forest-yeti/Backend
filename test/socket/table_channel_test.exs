defmodule Socket.Channels.TableChannelTest do
  @moduledoc """
  Канал стола насквозь: сообщение клиента → ядро → push. Несколько
  подключённых сокетов, поэтому Sandbox в режиме `:shared` и `async: false`.
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

    %{room_id: room_id, setting: setting, buy_in: CashGameSetting.min_buy_in_chips(setting)}
  end

  defp connect_player(room_id) do
    user = user_fixture()
    {:ok, socket} = connect(UserSocket, %{"token" => token(user)})
    {:ok, _reply, channel} = subscribe_and_join(socket, "table:#{room_id}", %{})
    %{user: user, channel: channel}
  end

  defp wait_for_seat_status(room_id, seat, status, attempts \\ 50) do
    {:ok, room} = BlockPoker.Tables.room_state(room_id)

    cond do
      Map.fetch!(room.seats, seat).status == status -> :ok
      attempts == 0 -> flunk("место #{seat} так и не перешло в #{status}")
      true -> Process.sleep(10) && wait_for_seat_status(room_id, seat, status, attempts - 1)
    end
  end

  defp token(user) do
    {:ok, %{token: token}} = BlockPoker.Accounts.start_session(user)
    token
  end

  test "join отдаёт персональный снапшот стола", %{room_id: room_id, setting: setting} do
    user = user_fixture()
    {:ok, socket} = connect(UserSocket, %{"token" => token(user)})

    {:ok, snapshot, _channel} = subscribe_and_join(socket, "table:#{room_id}", %{})

    assert snapshot.room_id == room_id
    assert snapshot.max_players == 6
    assert length(snapshot.seats) == 6
    assert snapshot.you == %{seated: false}
    # Косметика стола приезжает вместе со снапшотом.
    assert snapshot.visuals.felt_color == setting.felt_color
  end

  test "join_seat сажает игрока и списывает бай-ин", %{room_id: room_id, buy_in: buy_in} do
    %{channel: channel} = connect_player(room_id)

    ref = push(channel, "join_seat", %{"seat" => 3, "buy_in" => buy_in})

    assert_reply ref, :ok, %{seat: 3, stack: ^buy_in}
  end

  test "оба игрока за столом видят посадку соседа", %{room_id: room_id, buy_in: buy_in} do
    %{channel: first} = connect_player(room_id)
    %{channel: second} = connect_player(room_id)

    ref = push(first, "join_seat", %{"seat" => 1, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload

    assert_push "seat_taken", %{seat: 1}

    # Второй сокет получает то же событие: состояние стола общее.
    ref = push(second, "join_seat", %{"seat" => 2, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload
    assert_push "seat_taken", %{seat: 2}
  end

  test "событие приходит ровно один раз", %{room_id: room_id, buy_in: buy_in} do
    # Внутренний топик комнаты не должен совпадать с именем канала: на топик
    # своего имени Phoenix подписывает канал сам, и вторая подписка удваивала
    # бы каждое событие — клиент перезапрашивал бы снапшот на каждый чих.
    %{channel: channel} = connect_player(room_id)

    ref = push(channel, "join_seat", %{"seat" => 1, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload

    assert_push "seat_taken", %{seat: 1}
    refute_push "seat_taken", %{seat: 1}
  end

  test "второму на то же место приходит код seat_taken", %{room_id: room_id, buy_in: buy_in} do
    %{channel: first} = connect_player(room_id)
    %{channel: second} = connect_player(room_id)

    ref = push(first, "join_seat", %{"seat" => 4, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload

    ref = push(second, "join_seat", %{"seat" => 4, "buy_in" => buy_in})
    assert_reply ref, :error, %{code: "seat_taken"}
  end

  test "user_id из payload игнорируется: личность берётся из сокета", %{
    room_id: room_id,
    buy_in: buy_in
  } do
    %{channel: channel, user: user} = connect_player(room_id)
    other = user_fixture()

    ref = push(channel, "join_seat", %{"seat" => 2, "buy_in" => buy_in, "user_id" => other.id})
    assert_reply ref, :ok, _payload

    {:ok, room} = BlockPoker.Tables.room_state(room_id)
    assert Map.fetch!(room.seats, 2).user_id == user.id
  end

  test "кривой payload отвергается кодом валидации", %{room_id: room_id} do
    %{channel: channel} = connect_player(room_id)

    ref = push(channel, "join_seat", %{"seat" => "три", "buy_in" => 400})
    assert_reply ref, :error, %{code: "validation_failed"}

    # Дробные суммы в деньгах запрещены протоколом.
    ref = push(channel, "join_seat", %{"seat" => 3, "buy_in" => 4.5})
    assert_reply ref, :error, %{code: "validation_failed"}
  end

  test "бай-ин вне границ отвергается кодом, а не падением", %{room_id: room_id} do
    %{channel: channel} = connect_player(room_id)

    ref = push(channel, "join_seat", %{"seat" => 3, "buy_in" => 1})
    assert_reply ref, :error, %{code: "invalid_buy_in"}
  end

  test "leave_seat возвращает фишки и освобождает место", %{room_id: room_id, buy_in: buy_in} do
    %{channel: channel} = connect_player(room_id)
    ref = push(channel, "join_seat", %{"seat" => 3, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload

    ref = push(channel, "leave_seat", %{})
    assert_reply ref, :ok, %{cashed_out: ^buy_in}

    {:ok, room} = BlockPoker.Tables.room_state(room_id)
    assert Map.fetch!(room.seats, 3).status == :empty
  end

  test "повторное подключение возвращает игрока на своё место", %{
    room_id: room_id,
    buy_in: buy_in
  } do
    # Закрытие клиента не освобождает место, но и не должно оставлять игрока
    # навсегда «без связи»: подключение к столу — это и есть возвращение.
    %{user: user, channel: channel} = connect_player(room_id)

    ref = push(channel, "join_seat", %{"seat" => 4, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload

    # Канал слинкован с тестом, поэтому его уход не должен ронять тест.
    Process.unlink(channel.channel_pid)
    ref = leave(channel)
    assert_reply ref, :ok
    wait_for_seat_status(room_id, 4, :disconnected)

    {:ok, room} = BlockPoker.Tables.room_state(room_id)
    assert Map.fetch!(room.seats, 4).status == :disconnected

    {:ok, socket} = connect(UserSocket, %{"token" => token(user)})
    {:ok, snapshot, _channel} = subscribe_and_join(socket, "table:#{room_id}", %{})

    assert snapshot.you.seated
    assert snapshot.you.seat == 4
    assert snapshot.you.status == :playing
  end

  test "table_state отдаёт снапшот с местом игрока", %{room_id: room_id, buy_in: buy_in} do
    %{channel: channel} = connect_player(room_id)
    ref = push(channel, "join_seat", %{"seat" => 5, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload

    ref = push(channel, "table_state", %{})
    assert_reply ref, :ok, snapshot

    assert snapshot.you.seated
    assert snapshot.you.seat == 5
  end
end
