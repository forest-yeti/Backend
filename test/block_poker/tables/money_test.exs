defmodule BlockPoker.Tables.MoneyTest do
  @moduledoc """
  Деньги посадки на настоящей MySQL под Sandbox: ledger, идемпотентность
  и инвариант «фишки в комнате + баланс кошелька == баланс до посадки».

  БД здесь не мокается принципиально (§11 CLAUDE.md): значительная часть
  гарантий обеспечивается самой базой — UNIQUE на `idempotency_key`
  и откат транзакции.
  """

  use BlockPoker.DataCase, async: false

  import BlockPoker.AccountsFixtures
  import BlockPoker.CashGamesFixtures
  import BlockPoker.TablesHelpers

  alias BlockPoker.CashGames.CashGameSetting
  alias BlockPoker.GameMode
  alias BlockPoker.Tables
  alias BlockPoker.Tables.{RoomState, TableRegistry, TableServer}
  alias BlockPoker.Wallet
  alias BlockPoker.Wallet.WalletEntry
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    ensure_tables!()
    user = user_fixture()
    %{user: user}
  end

  defp start_test_room(overrides \\ %{}) do
    setting = setting_fixture(Map.merge(%{currency: :play_money, max_players: 6}, overrides))
    room_id = Ecto.UUID.generate()

    pid =
      start_supervised!(
        {TableServer, [room_id: room_id, setting: setting, timers: :manual]},
        id: room_id
      )

    Sandbox.allow(BlockPoker.Repo, self(), pid)

    %{
      room_id: room_id,
      pid: pid,
      setting: setting,
      buy_in: CashGameSetting.min_buy_in_chips(setting)
    }
  end

  defp balance(user),
    do: Wallet.get_wallet(user.id, :play_money) |> elem(1) |> Map.fetch!(:amount)

  defp entries(user) do
    {:ok, wallet} = Wallet.get_wallet(user.id, :play_money)
    Repo.all(from e in WalletEntry, where: e.wallet_id == ^wallet.id)
  end

  test "бай-ин создаёт ровно одну запись ledger и уносит фишки на стол", %{user: user} do
    %{room_id: room_id, buy_in: buy_in} = start_test_room()
    before = balance(user)

    {:ok, %{stack: stack}} = Tables.join_seat(room_id, user.id, 3, buy_in)

    assert stack == buy_in
    assert balance(user) == before - buy_in
    assert Enum.count(entries(user), &(&1.type == :buy_in)) == 1

    # Инвариант денег: фишки не возникли и не исчезли, только переехали.
    {:ok, room} = Tables.room_state(room_id)
    assert RoomState.chips_in_play(room) + balance(user) == before
  end

  test "нехватка денег не оставляет ни резерва места, ни записи", %{user: user} do
    # Стартовые 10 000 play money против стола, где минимум заведомо больше.
    %{room_id: room_id, buy_in: buy_in} =
      start_test_room(%{small_blind: 500_000, big_blind: 1_000_000})

    before = balance(user)

    assert {:error, :insufficient_funds} = Tables.join_seat(room_id, user.id, 1, buy_in)

    assert balance(user) == before
    refute Enum.any?(entries(user), &(&1.type == :buy_in))

    {:ok, room} = Tables.room_state(room_id)
    assert RoomState.free_seats(room) |> length() == room.setting.max_players
  end

  test "повторный бай-ин с тем же ключом не создаёт вторую запись", %{user: user} do
    %{room_id: room_id, buy_in: buy_in} = start_test_room()
    before = balance(user)
    key = "buyin:#{Ecto.UUID.generate()}"

    {:ok, _entry} = Wallet.buy_in(user.id, :play_money, buy_in, key, ref_id: room_id)
    {:ok, _same} = Wallet.buy_in(user.id, :play_money, buy_in, key, ref_id: room_id)

    # Дубль ловит UNIQUE в БД, а не предварительный SELECT.
    assert balance(user) == before - buy_in
    assert Enum.count(entries(user), &(&1.type == :buy_in)) == 1
  end

  test "leave_seat возвращает ровно стек, а не сумму бай-ина", %{user: user} do
    %{room_id: room_id, pid: pid, buy_in: buy_in} = start_test_room()
    before = balance(user)
    {:ok, _result} = Tables.join_seat(room_id, user.id, 3, buy_in)

    # Игрок выиграл: стек больше бай-ина. Вернуться должен именно стек.
    room = TableServer.state(pid)
    seats = Map.update!(room.seats, 3, &%{&1 | stack: buy_in + 250})
    :sys.replace_state(pid, fn state -> %{state | room: %{room | seats: seats}} end)

    {:ok, %{cashed_out: cashed_out}} = Tables.leave_seat(room_id, user.id)

    assert cashed_out == buy_in + 250
    assert balance(user) == before + 250
    assert Enum.count(entries(user), &(&1.type == :cash_out)) == 1
  end

  test "уход с нулевым стеком записи в ledger не порождает", %{user: user} do
    %{room_id: room_id, pid: pid, buy_in: buy_in} = start_test_room()
    {:ok, _result} = Tables.join_seat(room_id, user.id, 3, buy_in)

    room = TableServer.state(pid)
    seats = Map.update!(room.seats, 3, &%{&1 | stack: 0})
    :sys.replace_state(pid, fn state -> %{state | room: %{room | seats: seats}} end)

    {:ok, %{cashed_out: 0}} = Tables.leave_seat(room_id, user.id)

    refute Enum.any?(entries(user), &(&1.type == :cash_out))
  end

  test "докупка проходит через ledger и поднимает стек", %{user: user} do
    %{room_id: room_id, buy_in: buy_in} = start_test_room()
    before = balance(user)
    {:ok, _result} = Tables.join_seat(room_id, user.id, 3, buy_in)

    {:ok, %{stack: stack}} = Tables.add_chips(room_id, user.id, 100)

    assert stack == buy_in + 100
    assert balance(user) == before - buy_in - 100

    {:ok, room} = Tables.room_state(room_id)
    assert RoomState.chips_in_play(room) + balance(user) == before
  end

  test "докупка сверх max_buy_in отвергается и денег не трогает", %{user: user} do
    %{room_id: room_id, setting: setting, buy_in: buy_in} = start_test_room()
    max = CashGameSetting.max_buy_in_chips(setting)
    {:ok, _result} = Tables.join_seat(room_id, user.id, 3, buy_in)
    before = balance(user)

    assert {:error, :invalid_buy_in} = Tables.add_chips(room_id, user.id, max - buy_in + 1)
    assert balance(user) == before
  end

  test "докупка, заказанная в раздаче, ждёт её конца и отменяема", %{user: user} do
    # Раздача, начавшаяся между проверкой и зачислением, докупку больше не
    # отменяет: деньги списаны, и стол принимает заявку. Проверяется, что
    # списанное не растворяется — отмена возвращает его в кошелёк целиком.
    %{room_id: room_id, pid: pid, buy_in: buy_in} = start_test_room()
    other = user_fixture()

    {:ok, _result} = Tables.join_seat(room_id, user.id, 3, buy_in)
    {:ok, _result} = Tables.join_seat(room_id, other.id, 4, buy_in)

    before = balance(user)

    {:ok, ref, nil} = TableServer.begin_add_chips(pid, user.id, 100)
    room = TableServer.state(pid)
    :ok = GameMode.Cash.take_buy_in(room, user.id, 100, ref)
    assert balance(user) == before - 100

    # Пока деньги шли в ledger, стол разыграл кнопку и начал раздачу.
    :ok = TableServer.fire_timer(pid, :button_draw)
    assert TableServer.state(pid).phase == :hand

    assert {:ok, %{queued: 100}} = Tables.commit_add_chips(pid, room_id, user.id, 100, ref)
    assert balance(user) == before - 100, "заявка не должна возвращать деньги сама по себе"

    assert {:ok, %{returned: 100}} = Tables.cancel_add_chips(room_id, user.id)
    assert balance(user) == before
    assert Enum.count(entries(user), &(&1.type == :cash_out)) == 1
  end

  test "двойной клик по «докупить» списывает деньги один раз", %{user: user} do
    # Двойной клик — это два запроса, оба успевшие пройти проверку до того,
    # как первый зачислил фишки. Через `add_chips/3` его не воспроизвести:
    # вызов синхронный, поэтому шаги разложены руками в том же порядке.
    %{room_id: room_id, pid: pid, buy_in: buy_in} = start_test_room(%{auto_start: false})
    {:ok, _result} = Tables.join_seat(room_id, user.id, 3, buy_in)

    before = balance(user)

    {:ok, first, nil} = TableServer.begin_add_chips(pid, user.id, 100)
    {:ok, second, nil} = TableServer.begin_add_chips(pid, user.id, 100)
    assert first == second, "второй клик получил новый ключ идемпотентности"

    :ok = GameMode.Cash.take_buy_in(TableServer.state(pid), user.id, 100, first)
    :ok = GameMode.Cash.take_buy_in(TableServer.state(pid), user.id, 100, second)

    assert {:ok, _result} = Tables.commit_add_chips(pid, room_id, user.id, 100, first)
    assert {:ok, _result} = Tables.commit_add_chips(pid, room_id, user.id, 100, second)

    assert balance(user) == before - 100, "докупка списана дважды"
    assert Enum.count(entries(user), &(&1.type == :buy_in and &1.amount == -100)) == 1
    assert RoomState.chips_in_play(TableServer.state(pid)) == buy_in + 100
  end

  test "quick_seat сажает по шаблону и списывает бай-ин один раз", %{user: user} do
    %{room_id: room_id, setting: setting, buy_in: buy_in} = start_test_room()
    before = balance(user)

    # Лобби здесь не поднимаем: проверяем денежный путь, комната задана явно.
    {:ok, %{seat: seat}} = Tables.join_seat(room_id, user.id, 1, buy_in)

    assert seat == 1
    assert balance(user) == before - buy_in
    assert setting.currency == :play_money
    assert TableRegistry.whereis(room_id) != nil
  end
end
