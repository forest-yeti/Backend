defmodule Socket.Channels.LobbyChannelTest do
  @moduledoc """
  Лобби насквозь: витрина лимитов, пуш при изменении занятости и быстрый вход.
  """

  use Socket.ChannelCase, async: false

  import BlockPoker.AccountsFixtures
  import BlockPoker.CashGamesFixtures
  import BlockPoker.TablesHelpers

  alias BlockPoker.CashGames.CashGameSetting
  alias BlockPoker.Tables.{Lobby, TableRegistry}
  alias Ecto.Adapters.SQL.Sandbox
  alias Socket.UserSocket

  setup do
    ensure_tables!()
    setting = setting_fixture(%{currency: :play_money, max_players: 2})

    pid = start_supervised!({Lobby, reload_ms: nil, room_opts: [timers: :manual]})
    Sandbox.allow(BlockPoker.Repo, self(), pid)
    :ok = Lobby.reload()

    %{setting: setting, buy_in: CashGameSetting.min_buy_in_chips(setting)}
  end

  defp socket_for do
    user = user_fixture()
    {:ok, %{token: token}} = BlockPoker.Accounts.start_session(user)
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    socket
  end

  defp join_lobby do
    user = user_fixture()
    {:ok, %{token: token}} = BlockPoker.Accounts.start_session(user)
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    {:ok, snapshot, channel} = subscribe_and_join(socket, "lobby", %{})
    %{user: user, channel: channel, snapshot: snapshot}
  end

  test "join отдаёт список шаблонов с комнатами", %{setting: setting} do
    %{snapshot: snapshot} = join_lobby()

    assert [shown] = Enum.filter(snapshot.settings, &(&1.setting_id == setting.id))
    assert shown.max_players == 2
    assert shown.players_total == 0

    # Пустой лимит показывается: игрок должен видеть, куда он может сесть.
    assert [%{seats_taken: 0}] = shown.rooms
    assert shown.visuals.felt_color == setting.felt_color
    assert shown.min_buy_in == CashGameSetting.min_buy_in_chips(setting)
  end

  test "quick_seat сажает по лимиту, а не по комнате", %{setting: setting, buy_in: buy_in} do
    %{channel: channel} = join_lobby()

    ref = push(channel, "quick_seat", %{"setting_id" => setting.id, "buy_in" => buy_in})

    assert_reply ref, :ok, %{seat: 1, stack: ^buy_in}
  end

  test "посадка одного игрока доезжает пушем до всех подписчиков лобби", %{
    setting: setting,
    buy_in: buy_in
  } do
    %{channel: first} = join_lobby()
    %{channel: _second} = join_lobby()

    ref = push(first, "quick_seat", %{"setting_id" => setting.id, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload

    # Опроса нет: лобби обновляется пушем.
    assert_push "lobby_delta", delta
    assert delta.setting_id == setting.id
    assert delta.players_total == 1
  end

  test "заполнение комнаты порождает новую и это видно в лобби", %{
    setting: setting,
    buy_in: buy_in
  } do
    %{channel: channel} = join_lobby()

    for _player <- 1..2 do
      %{channel: seat_channel} = join_lobby()
      ref = push(seat_channel, "quick_seat", %{"setting_id" => setting.id, "buy_in" => buy_in})
      assert_reply ref, :ok, _payload
    end

    ref = push(channel, "list", %{})
    assert_reply ref, :ok, snapshot

    [shown] = Enum.filter(snapshot.settings, &(&1.setting_id == setting.id))
    assert length(shown.rooms) == 2
    assert Enum.count(shown.rooms, &(&1.seats_taken < &1.max_players)) == 1
  end

  test "ping отвечает и в лобби: замер не привязан к столу" do
    %{channel: channel} = join_lobby()
    sent_at = System.system_time(:millisecond)

    ref = push(channel, "ping", %{"t" => sent_at})
    assert_reply ref, :ok, %{client_time: ^sent_at}
  end

  test "неизвестный шаблон отвергается кодом", %{buy_in: buy_in} do
    %{channel: channel} = join_lobby()

    ref = push(channel, "quick_seat", %{"setting_id" => Ecto.UUID.generate(), "buy_in" => buy_in})
    assert_reply ref, :error, %{code: "no_seats_available"}
  end

  test "нецелая сумма отвергается до контекста", %{setting: setting} do
    %{channel: channel} = join_lobby()

    ref = push(channel, "quick_seat", %{"setting_id" => setting.id, "buy_in" => "много"})
    assert_reply ref, :error, %{code: "validation_failed"}
  end

  defp join_lobby(params) do
    user = user_fixture()
    {:ok, %{token: token}} = BlockPoker.Accounts.start_session(user)
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    {:ok, snapshot, channel} = subscribe_and_join(socket, "lobby", params)
    %{user: user, channel: channel, snapshot: snapshot}
  end

  # Шаблон на реальные деньги нужен рядом с игровым: фильтры и порядок
  # видно только там, где валют больше одной.
  defp main_setting! do
    setting = setting_fixture(%{name: "NL10", currency: :main, small_blind: 5, big_blind: 10})
    :ok = Lobby.reload()
    setting
  end

  test "по умолчанию main идёт выше play_money", %{setting: play} do
    main = main_setting!()

    %{snapshot: snapshot} = join_lobby()
    ids = Enum.map(snapshot.settings, & &1.setting_id)

    assert Enum.find_index(ids, &(&1 == main.id)) < Enum.find_index(ids, &(&1 == play.id))
  end

  test "фильтр по валюте и категории отдаёт только подходящие лимиты", %{setting: play} do
    main = main_setting!()

    %{channel: channel} = join_lobby()

    ref =
      push(channel, "list", %{
        "currencies" => ["main"],
        "limit_tiers" => ["micro"],
        "game_types" => ["texas_holdem"]
      })

    assert_reply ref, :ok, snapshot

    ids = Enum.map(snapshot.settings, & &1.setting_id)
    assert main.id in ids
    refute play.id in ids
  end

  test "витрина приходит с категориями и списком допустимых фильтров" do
    main = main_setting!()

    %{snapshot: snapshot} = join_lobby()
    [shown] = Enum.filter(snapshot.settings, &(&1.setting_id == main.id))

    assert shown.limit_tier == :micro
    assert shown.table_size == :six_max
    assert shown.seats_taken == 0
    assert :play_money in snapshot.filters.currencies
    assert :high_roller in snapshot.filters.limit_tiers
  end

  test "неизвестное значение фильтра отвергается кодом" do
    %{channel: channel} = join_lobby()

    ref = push(channel, "list", %{"currencies" => ["bitcoin"]})
    assert_reply ref, :error, %{code: "validation_failed"}
  end

  test "отфильтрованный лимит не шлёт подписчику lobby_delta", %{
    setting: setting,
    buy_in: buy_in
  } do
    _main = main_setting!()

    # Один подписчик на всю проверку: пуши каналов приходят в почтовый ящик
    # теста общим потоком, и второй, нефильтрованный, сокет её бы обнулил.
    %{channel: watcher} = join_lobby(%{"currencies" => ["main"]})

    ref = push(watcher, "quick_seat", %{"setting_id" => setting.id, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload

    # Занятость игрового лимита изменилась, но подписчик смотрит на main.
    refute_push "lobby_delta", _delta
  end

  test "вход по коду: превью комнаты, которой нет в общей сетке" do
    private = private_setting_fixture(%{small_blind: 25, big_blind: 50, max_players: 6})
    :ok = Lobby.reload()

    %{channel: channel, snapshot: snapshot} = join_lobby()

    # В витрине закрытой комнаты нет — ни при join, ни в списке.
    refute Enum.any?(snapshot.settings, &(&1.setting_id == private.id))

    ref = push(channel, "find_by_code", %{"code" => String.upcase(private.code)})
    assert_reply ref, :ok, found

    assert found.setting_id == private.id
    assert found.small_blind == 25
    assert found.max_players == 6
    assert found.seats_taken == 0
    assert found.free_seats == 6
    assert found.min_buy_in == CashGameSetting.min_buy_in_chips(private)

    # Дальше — обычная посадка в топике стола, отдельного пути для кода нет.
    {:ok, _reply, table} = subscribe_and_join(socket_for(), "table:#{found.room_id}", %{})
    ref = push(table, "join_seat", %{"seat" => 1, "buy_in" => found.min_buy_in})
    assert_reply ref, :ok, %{seat: 1}
  end

  test "неизвестный код не находит ничего" do
    %{channel: channel} = join_lobby()

    for code <- ["zzzzzz", "мусор", ""] do
      ref = push(channel, "find_by_code", %{"code" => code})
      assert_reply ref, :error, %{code: "not_found"}
    end
  end

  test "заполненная закрытая комната отвечает «мест нет», а не «не найдено»" do
    private = private_setting_fixture(%{small_blind: 25, big_blind: 50, max_players: 2})
    :ok = Lobby.reload()

    [%{room_id: room_id}] = Lobby.rooms_for(private.id)
    pid = TableRegistry.whereis(room_id)
    buy_in = CashGameSetting.min_buy_in_chips(private)
    Enum.each(1..2, &seat!(pid, "user-#{&1}", &1, buy_in))

    %{channel: channel} = join_lobby()

    ref = push(channel, "find_by_code", %{"code" => private.code})
    assert_reply ref, :error, %{code: "no_seats_available"}
  end

  test "my_seats отвечает, за какими столами игрок уже сидит", %{setting: setting, buy_in: buy_in} do
    %{user: user, channel: channel} = join_lobby()

    ref = push(channel, "my_seats", %{})
    assert_reply ref, :ok, %{seats: []}

    ref = push(channel, "quick_seat", %{"setting_id" => setting.id, "buy_in" => buy_in})
    assert_reply ref, :ok, %{room_id: room_id}

    # Закрытое окно стола места не освобождает, и лобби обязано уметь
    # сказать, куда возвращаться: иначе игроку доступна только «Сесть»,
    # а она честно отвечает already_seated.
    ref = push(channel, "my_seats", %{})
    assert_reply ref, :ok, %{seats: [seat]}
    assert seat.room_id == room_id
    assert seat.setting_id == setting.id
    assert seat.seat == 1

    assert TableRegistry.whereis(room_id) != nil
    assert user.id != nil
  end

  test "set_avatar меняет метку аватара" do
    %{user: user, channel: channel} = join_lobby()

    assert user.avatar == "First"

    ref = push(channel, "set_avatar", %{"avatar" => "Third"})
    assert_reply ref, :ok, %{avatar: "Third"}

    assert {:ok, updated} = BlockPoker.Accounts.get_user(user.id)
    assert updated.avatar == "Third"
  end

  test "неизвестная метка аватара отвергается" do
    %{user: user, channel: channel} = join_lobby()

    ref = push(channel, "set_avatar", %{"avatar" => "Sixth"})
    assert_reply ref, :error, %{code: "validation_failed"}

    assert {:ok, unchanged} = BlockPoker.Accounts.get_user(user.id)
    assert unchanged.avatar == "First"
  end
end
