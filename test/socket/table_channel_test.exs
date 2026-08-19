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

  defp room_pid(room_id), do: BlockPoker.Tables.TableRegistry.whereis(room_id)

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
    assert snapshot.you == %{seated: false, can_react: false}
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

  test "раздача стартует, карты уходят адресно, ход подсказывается", %{
    room_id: room_id,
    buy_in: buy_in
  } do
    %{channel: first} = connect_player(room_id)
    %{channel: second} = connect_player(room_id)

    ref = push(first, "join_seat", %{"seat" => 1, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload
    ref = push(second, "join_seat", %{"seat" => 2, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload

    :ok = TableServer.fire_timer(room_pid(room_id), :button_draw)

    assert_push "hand_started", %{}
    assert_push "action_prompt", prompt
    assert prompt.legal_actions.fold

    # Карманные карты приходят каждому свои и не уходят в общий топик.
    assert_push "your_cards", %{cards: cards}
    assert length(cards) == 2

    ref = push(first, "table_state", %{})
    assert_reply ref, :ok, snapshot
    assert snapshot.hand.street == :preflop
    assert length(snapshot.you.hole_cards) == 2
  end

  test "чужого хода не бывает: действие вне очереди отклоняется", %{
    room_id: room_id,
    buy_in: buy_in
  } do
    %{channel: first} = connect_player(room_id)
    %{channel: second} = connect_player(room_id)

    ref = push(first, "join_seat", %{"seat" => 1, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload
    ref = push(second, "join_seat", %{"seat" => 2, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload

    :ok = TableServer.fire_timer(room_pid(room_id), :button_draw)
    assert_push "action_prompt", prompt

    waiting = if prompt.seat == 1, do: second, else: first
    ref = push(waiting, "action", %{"type" => "call"})
    assert_reply ref, :error, %{code: "not_your_turn"}
  end

  test "чат доходит до всех за столом", %{room_id: room_id, buy_in: buy_in} do
    %{channel: first} = connect_player(room_id)
    %{channel: _second} = connect_player(room_id)

    ref = push(first, "join_seat", %{"seat" => 1, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload

    ref = push(first, "chat", %{"text" => "  всем удачи  "})
    assert_reply ref, :ok, %{text: "всем удачи"}

    assert_push "chat_message", %{seat: 1, text: "всем удачи"}
  end

  test "наблюдатель писать не может", %{room_id: room_id} do
    %{channel: channel} = connect_player(room_id)

    ref = push(channel, "chat", %{"text" => "привет"})
    assert_reply ref, :error, %{code: "not_seated"}
  end

  test "пустое сообщение отвергается формой", %{room_id: room_id, buy_in: buy_in} do
    %{channel: channel} = connect_player(room_id)
    ref = push(channel, "join_seat", %{"seat" => 1, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload

    ref = push(channel, "chat", %{"text" => "   "})
    assert_reply ref, :error, %{code: "validation_failed"}
  end

  test "преселект принимается и снимается тем же сообщением", %{
    room_id: room_id,
    buy_in: buy_in
  } do
    %{channel: channel} = connect_player(room_id)
    ref = push(channel, "join_seat", %{"seat" => 1, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload

    ref = push(channel, "preselect", %{"action" => "check_fold"})
    assert_reply ref, :ok, _payload

    ref = push(channel, "table_state", %{})
    assert_reply ref, :ok, snapshot
    assert snapshot.you.preselect == :check_fold

    ref = push(channel, "preselect", %{"action" => "none"})
    assert_reply ref, :ok, _payload

    ref = push(channel, "table_state", %{})
    assert_reply ref, :ok, snapshot
    assert snapshot.you.preselect == nil
  end

  test "неизвестный преселект отвергается", %{room_id: room_id, buy_in: buy_in} do
    %{channel: channel} = connect_player(room_id)
    ref = push(channel, "join_seat", %{"seat" => 1, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload

    ref = push(channel, "preselect", %{"action" => "raise_pot"})
    assert_reply ref, :error, %{code: "validation_failed"}
  end

  test "post_blind — намерение, а не мгновенный вход", %{room_id: room_id, buy_in: buy_in} do
    %{channel: first} = connect_player(room_id)
    %{channel: second} = connect_player(room_id)
    %{channel: third} = connect_player(room_id)

    ref = push(first, "join_seat", %{"seat" => 1, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload
    ref = push(second, "join_seat", %{"seat" => 2, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload

    :ok = TableServer.fire_timer(room_pid(room_id), :button_draw)

    ref = push(third, "join_seat", %{"seat" => 4, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload

    ref = push(third, "post_blind", %{})
    assert_reply ref, :ok, _payload

    ref = push(third, "table_state", %{})
    assert_reply ref, :ok, snapshot
    assert snapshot.you.wants_post

    # Снять намерение — тем же сообщением.
    ref = push(third, "post_blind", %{"post" => false})
    assert_reply ref, :ok, _payload

    ref = push(third, "table_state", %{})
    assert_reply ref, :ok, snapshot
    refute snapshot.you.wants_post
  end

  test "ручной запуск стола доступен только администратору", %{} do
    setting =
      setting_fixture(%{currency: :play_money, small_blind: 1, big_blind: 2, auto_start: false})

    room_id = Ecto.UUID.generate()

    pid =
      start_supervised!(
        {TableServer, [room_id: room_id, setting: setting, timers: :manual]},
        id: room_id
      )

    Sandbox.allow(BlockPoker.Repo, self(), pid)

    buy_in = CashGameSetting.min_buy_in_chips(setting)

    %{user: admin, channel: first} = connect_player(room_id)
    {:ok, _admin} = BlockPoker.Accounts.set_role(admin, :admin)
    %{channel: second} = connect_player(room_id)

    # Роль снимается при посадке, поэтому назначена она до join_seat.
    ref = push(first, "join_seat", %{"seat" => 1, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload
    ref = push(second, "join_seat", %{"seat" => 2, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload

    # Стол собран, но сам не стартует.
    ref = push(second, "table_state", %{})
    assert_reply ref, :ok, snapshot
    assert snapshot.phase == :idle
    refute snapshot.you.can_start_manual

    ref = push(second, "start_game", %{})
    assert_reply ref, :error, %{code: "start_not_available"}

    ref = push(first, "table_state", %{})
    assert_reply ref, :ok, snapshot
    assert snapshot.you.can_start_manual

    ref = push(first, "start_game", %{})
    assert_reply ref, :ok, _payload

    assert_push "button_draw", _payload

    ref = push(first, "table_state", %{})
    assert_reply ref, :ok, snapshot
    assert snapshot.phase == :button_draw
    refute snapshot.you.can_start_manual
  end

  test "играющему post_blind отвечает кодом", %{room_id: room_id, buy_in: buy_in} do
    %{channel: channel} = connect_player(room_id)
    ref = push(channel, "join_seat", %{"seat" => 1, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload

    ref = push(channel, "post_blind", %{})
    assert_reply ref, :error, %{code: "post_not_available"}
  end

  test "реакция доезжает до всех за столом и держит кулдаун", %{
    room_id: room_id,
    buy_in: buy_in
  } do
    %{channel: first} = connect_player(room_id)
    %{channel: second} = connect_player(room_id)

    ref = push(first, "join_seat", %{"seat" => 1, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload
    ref = push(second, "join_seat", %{"seat" => 2, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload

    ref = push(first, "reaction", %{"id" => "fire"})
    assert_reply ref, :ok, _payload

    # Видят все в топике, включая самого отправителя.
    assert_push "reaction", %{seat: 1, id: "fire"}

    # Вторая в ту же минуту — отказ с остатком времени, а не молчание.
    ref = push(first, "reaction", %{"id" => "gg"})
    assert_reply ref, :error, %{code: "reaction_rate_limited", retry_after_ms: remaining}
    assert remaining > 0

    # Сосед не ограничен чужим кулдауном.
    ref = push(second, "reaction", %{"id" => "gg"})
    assert_reply ref, :ok, _payload
  end

  test "неизвестный id реакции отвергается", %{room_id: room_id, buy_in: buy_in} do
    %{channel: channel} = connect_player(room_id)
    ref = push(channel, "join_seat", %{"seat" => 1, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload

    for id <- ["rocket", "🔥", "", nil] do
      ref = push(channel, "reaction", %{"id" => id})
      assert_reply ref, :error, %{code: "validation_failed"}
    end
  end

  test "наблюдателю реакции недоступны", %{room_id: room_id} do
    %{channel: channel} = connect_player(room_id)

    ref = push(channel, "reaction", %{"id" => "fire"})
    assert_reply ref, :error, %{code: "not_seated"}
  end

  test "реакция не переигрывается при реконнекте", %{room_id: room_id, buy_in: buy_in} do
    %{channel: first} = connect_player(room_id)
    ref = push(first, "join_seat", %{"seat" => 1, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload

    ref = push(first, "reaction", %{"id" => "fire"})
    assert_reply ref, :ok, _payload
    assert_push "reaction", %{id: "fire"}

    # Подключившийся следом получает снапшот без чужих смайликов.
    %{channel: second} = connect_player(room_id)
    ref = push(second, "table_state", %{})
    assert_reply ref, :ok, snapshot

    assert snapshot.reactions == BlockPoker.Reactions.ids()
    refute snapshot.you.can_react
    refute_push "reaction", _payload
  end

  test "ping возвращает метку клиента и время сервера", %{room_id: room_id} do
    %{channel: channel} = connect_player(room_id)
    sent_at = System.system_time(:millisecond)

    ref = push(channel, "ping", %{"t" => sent_at})
    assert_reply ref, :ok, pong

    # Метка возвращается как есть: круговую задержку считает клиент, у него
    # одни часы на оба конца замера.
    assert pong.client_time == sent_at
    assert is_integer(pong.server_time)
  end

  test "ping работает и без метки — тогда это просто проверка живости", %{room_id: room_id} do
    %{channel: channel} = connect_player(room_id)

    ref = push(channel, "ping", %{})
    assert_reply ref, :ok, %{client_time: nil, server_time: server_time}
    assert is_integer(server_time)
  end

  describe "уборка канала" do
    alias Socket.Channels.TableChannel

    test "join отвергнут — terminate не падает на отсутствующем room_id" do
      # `room_id` появляется в `assigns` только после успешного join; на
      # отказанном его нет, и уборка обязана это пережить молча.
      socket = %Phoenix.Socket{assigns: %{user_id: Ecto.UUID.generate()}}

      assert :ok = TableChannel.terminate(:shutdown, socket)
    end

    test "комнаты уже нет — terminate не падает на мёртвом процессе", %{room_id: room_id} do
      %{user: user} = connect_player(room_id)
      pid = room_pid(room_id)

      # Комната падает — это одна из причин, по которым канал закрывается.
      Process.exit(pid, :kill)
      wait_until_dead(pid)

      socket = %Phoenix.Socket{assigns: %{user_id: user.id, room_id: room_id}}
      assert :ok = TableChannel.terminate(:shutdown, socket)
    end

    defp wait_until_dead(pid, attempts \\ 50) do
      cond do
        not Process.alive?(pid) -> :ok
        attempts == 0 -> flunk("комната так и не завершилась")
        true -> Process.sleep(10) && wait_until_dead(pid, attempts - 1)
      end
    end
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
