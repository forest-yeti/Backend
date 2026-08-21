defmodule BlockPoker.Tables.LobbyTest do
  @moduledoc """
  Пул комнат: инвариант «ровно одна комната со свободными местами».

  Тест ходит в БД, потому что шаблоны лобби читает оттуда, но игра здесь
  ни при чём — проверяется поведение пула.
  """

  use BlockPoker.DataCase, async: false

  import BlockPoker.CashGamesFixtures
  import BlockPoker.TablesHelpers

  alias BlockPoker.CashGames
  alias BlockPoker.CashGames.CashGameSetting
  alias BlockPoker.Tables.{Lobby, TableRegistry, TableServer}
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    ensure_tables!()
    :ok
  end

  defp start_lobby! do
    name = :"lobby_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {Lobby, name: name, reload_ms: nil, room_opts: [timers: :manual]},
        id: name
      )

    Sandbox.allow(BlockPoker.Repo, self(), pid)

    # Лобби читало БД до выдачи доступа к Sandbox — перечитываем уже с ним.
    :ok = Lobby.reload(name)
    name
  end

  defp rooms(lobby, %{id: id}), do: rooms(lobby, id)
  defp rooms(lobby, setting_id), do: Lobby.rooms_for(lobby, setting_id)

  # Блайнды у каждого шаблона свои (естественный ключ уникален), поэтому
  # бай-ин считается от шаблона, а не берётся числом.
  defp buy_in(setting), do: CashGameSetting.min_buy_in_chips(setting)

  defp fill_room(room_id, setting) do
    pid = TableRegistry.whereis(room_id)
    Enum.each(1..setting.max_players, &seat!(pid, "user-#{room_id}-#{&1}", &1, buy_in(setting)))
    pid
  end

  test "при старте под каждый включённый шаблон поднимается пустая комната" do
    setting = setting_fixture(%{max_players: 6})
    lobby = start_lobby!()

    assert [room] = rooms(lobby, setting)
    assert room.seats_taken == 0
  end

  test "выключенный шаблон комнат не порождает" do
    setting = setting_fixture(%{enabled: false})
    lobby = start_lobby!()

    assert rooms(lobby, setting) == []
  end

  test "заполнение последней комнаты немедленно порождает новую" do
    setting = setting_fixture(%{max_players: 2})
    lobby = start_lobby!()
    [%{room_id: room_id}] = rooms(lobby, setting)

    fill_room(room_id, setting)

    rooms = rooms(lobby, setting)
    assert length(rooms) == 2

    # Инвариант: свободная комната ровно одна, и она новая.
    assert [free] = Enum.filter(rooms, &(&1.seats_taken < &1.max_players))
    assert free.room_id != room_id
  end

  test "опустевшая лишняя комната закрывается, последняя свободная — никогда" do
    setting = setting_fixture(%{max_players: 2})
    lobby = start_lobby!()
    [%{room_id: first_id}] = rooms(lobby, setting)

    pid = fill_room(first_id, setting)
    assert length(rooms(lobby, setting)) == 2

    # Игроки ушли — заполненная комната освободилась, и теперь свободных две.
    Enum.each(1..2, fn seat ->
      user_id = "user-#{first_id}-#{seat}"
      {:ok, %{ref: ref}} = TableServer.begin_leave(pid, user_id)
      :ok = TableServer.finish_leave(pid, ref)
    end)

    assert [_single] = rooms(lobby, setting)
  end

  test "reload поднимает комнату под новый шаблон" do
    lobby = start_lobby!()
    setting = setting_fixture(%{})

    assert rooms(lobby, setting) == []
    :ok = Lobby.reload(lobby)
    assert [_room] = rooms(lobby, setting)
  end

  test "reload уводит комнаты выключенного шаблона в :draining" do
    setting = setting_fixture(%{})
    lobby = start_lobby!()
    [%{room_id: room_id}] = rooms(lobby, setting)
    pid = TableRegistry.whereis(room_id)
    seat!(pid, "user-1", 1, buy_in(setting))

    {:ok, _setting} = CashGames.set_enabled(setting, false)
    :ok = Lobby.reload(lobby)

    # Комната с игроком не исчезает, а помечается: доигрывает и закрывается.
    assert TableServer.state(pid).draining?
    assert {:error, :room_closing} = TableServer.reserve_seat(pid, "user-2", 2, buy_in(setting))
  end

  test "падение комнаты восстанавливает инвариант новой комнатой" do
    setting = setting_fixture(%{})
    lobby = start_lobby!()
    [%{room_id: room_id}] = rooms(lobby, setting)

    pid = TableRegistry.whereis(room_id)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    # Синхронизация без sleep, и порядок здесь важен. `Process.exit/2`
    # асинхронен: сразу за ним лобби могло ещё не получить `:DOWN`, и
    # снапшот показывал бы умершую комнату живой — отсюда флак.
    #
    # Свой `:DOWN` приходит тогда же, когда рассылаются все остальные:
    # мониторы уведомляются в момент смерти процесса. Дождавшись его, мы
    # знаем, что `:DOWN` лобби уже лежит в его почтовом ящике, и следующий
    # `call` встанет в очередь за ним, а не перед.
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    _sync = Lobby.snapshot(lobby)

    assert [room] = rooms(lobby, setting)
    assert room.room_id != room_id
  end

  test "снапшот показывает все включённые шаблоны, включая пустые" do
    higher = setting_fixture(%{small_blind: 25, big_blind: 50})
    lower = setting_fixture(%{small_blind: 5, big_blind: 10})
    lobby = start_lobby!()

    ids = lobby |> Lobby.snapshot() |> Enum.map(& &1.setting.id)

    # Порядок витрины задаёт `LobbyQuery`: младший лимит выше старшего,
    # независимо от порядка создания строк.
    assert Enum.find_index(ids, &(&1 == lower.id)) < Enum.find_index(ids, &(&1 == higher.id))
  end

  test "quick_seat на хедз-апе подсаживает к ждущему, а не в пустую комнату" do
    setting = setting_fixture(%{max_players: 2})
    lobby = start_lobby!()
    [%{room_id: waiting_id}] = rooms(lobby, setting)

    seat!(TableRegistry.whereis(waiting_id), "user-1", 1, buy_in(setting))

    # Появилась вторая, пустая комната — но выбрана должна быть первая.
    assert {:ok, ^waiting_id} = Lobby.open_room(lobby, setting.id)
  end

  test "закрытая комната есть в пуле, но её нет в витрине лобби" do
    private = private_setting_fixture(%{small_blind: 25, big_blind: 50})
    public = setting_fixture(%{small_blind: 5, big_blind: 10})
    lobby = start_lobby!()

    ids = lobby |> Lobby.snapshot() |> Enum.map(& &1.setting.id)

    assert public.id in ids
    refute private.id in ids

    # Комната при этом поднята: по коду в неё можно сесть.
    assert [%{seats_taken: 0}] = rooms(lobby, private.id)
  end

  test "закрытая комната не порождает вторую, даже когда заполнилась" do
    private = private_setting_fixture(%{max_players: 2})
    lobby = start_lobby!()
    [%{room_id: room_id}] = rooms(lobby, private.id)

    fill_room(room_id, private)
    _sync = Lobby.snapshot(lobby)

    # Публичный лимит на этом месте открыл бы вторую комнату — у закрытой
    # код ведёт в одну и ту же, и «мест нет» здесь честный ответ.
    assert [%{room_id: ^room_id}] = rooms(lobby, private.id)
    assert {:error, :no_seats_available} = Lobby.open_room(lobby, private.id)
  end
end
