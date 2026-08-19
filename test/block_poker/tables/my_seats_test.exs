defmodule BlockPoker.Tables.MySeatsTest do
  @moduledoc """
  Возврат за свой стол.

  Закрытое окно стола места не освобождает — это осознанное решение
  (§«Мультитейбл» CLAUDE.md клиента): игрок вышел из интерфейса, а не
  из-за стола. Но тогда должен быть путь обратно, иначе единственное, что
  игрок может нажать в лобби, — «Сесть», а она честно отвечает
  `already_seated` и выглядит поломкой.

  Здесь проверяются обе половины этого пути: список своих мест и то, что
  быстрый вход не спотыкается о комнату, в которой игрок уже сидит.
  """

  use BlockPoker.DataCase, async: false

  import BlockPoker.AccountsFixtures
  import BlockPoker.CashGamesFixtures
  import BlockPoker.TablesHelpers

  alias BlockPoker.CashGames.CashGameSetting
  alias BlockPoker.Tables
  alias BlockPoker.Tables.{Lobby, TableRegistry}
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    ensure_tables!()
    user = user_fixture()
    %{user: user}
  end

  # Лобби в тестовой среде не поднимается (`start_lobby: false`), а
  # `Tables.quick_seat/4` и `Tables.my_seats/1` адресуются ему по имени
  # модуля — поднимаем его под этим именем на время теста.
  defp start_lobby! do
    pid =
      start_supervised!(
        {Lobby, name: Lobby, reload_ms: nil, room_opts: [timers: :manual]},
        id: :lobby_global
      )

    Sandbox.allow(BlockPoker.Repo, self(), pid)
    :ok = Lobby.reload(Lobby)
    pid
  end

  test "my_seats показывает комнату, за которой игрок сидит", %{user: user} do
    setting = setting_fixture(%{currency: :play_money, max_players: 6})
    start_lobby!()
    buy_in = CashGameSetting.min_buy_in_chips(setting)

    assert Tables.my_seats(user.id) == []

    {:ok, %{room_id: room_id, seat: seat}} = Tables.quick_seat(setting.id, user.id, buy_in)

    assert [%{room_id: ^room_id, seat: ^seat, setting_id: setting_id}] = Tables.my_seats(user.id)
    assert setting_id == setting.id
  end

  test "уход из-за стола убирает место из списка", %{user: user} do
    setting = setting_fixture(%{currency: :play_money, max_players: 6})
    start_lobby!()
    buy_in = CashGameSetting.min_buy_in_chips(setting)

    {:ok, %{room_id: room_id}} = Tables.quick_seat(setting.id, user.id, buy_in)
    {:ok, _result} = Tables.leave_seat(room_id, user.id)

    assert Tables.my_seats(user.id) == []
  end

  test "quick_seat уводит в другую комнату, а не отказывает своим же местом", %{user: user} do
    # Хедз-ап: своя комната заполняется вторым игроком, и по инварианту
    # лобби рядом открывается вторая — свободная.
    setting = setting_fixture(%{currency: :play_money, max_players: 2})
    lobby = start_lobby!()
    buy_in = CashGameSetting.min_buy_in_chips(setting)

    {:ok, %{room_id: first_room}} = Tables.quick_seat(setting.id, user.id, buy_in)
    seat!(TableRegistry.whereis(first_room), Ecto.UUID.generate(), 2, buy_in)
    _sync = Lobby.snapshot(lobby)

    # Самая полная комната лимита — та, где игрок уже сидит. Раньше
    # `already_seated` из неё обрывал перебор, и быстрый вход переставал
    # работать вовсе; теперь она просто пропускается.
    assert {:ok, %{room_id: second_room}} = Tables.quick_seat(setting.id, user.id, buy_in)
    assert second_room != first_room

    assert Tables.my_seats(user.id) |> Enum.map(& &1.room_id) |> Enum.sort() ==
             Enum.sort([first_room, second_room])
  end
end
