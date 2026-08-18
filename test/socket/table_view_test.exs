defmodule Socket.Views.TableViewTest do
  @moduledoc """
  Инвариант приватности (§11 CLAUDE.md): в том, что реально уходит в сокет,
  не должно быть данных, которых игрок знать не должен.

  Проверка идёт по **сырому JSON**, а не по структуре: структура может
  выглядеть чистой, а в сокет уйдёт лишнее поле — тест обязан ловить именно
  второе. Карманных карт в этой задаче ещё нет, но точка фильтрации и её
  проверка существуют с первого дня.
  """

  use ExUnit.Case, async: true

  import BlockPoker.CashGamesFixtures

  alias BlockPoker.Tables.RoomState
  alias Socket.Views.TableView

  setup do
    room = RoomState.new(Ecto.UUID.generate(), build_setting(%{max_players: 6}))
    {:ok, room} = RoomState.reserve(room, 1, "me", "res-1", %{name: "Hero", avatar: "/a.png"})
    {:ok, room, _seat} = RoomState.confirm(room, "res-1", 400, :wait_bb)

    {:ok, room} =
      RoomState.reserve(room, 4, "opponent", "res-2", %{name: "Villain", avatar: "/b.png"})

    {:ok, room, _seat} = RoomState.confirm(room, "res-2", 600, :wait_bb)

    %{room: room}
  end

  defp payload(room, user_id), do: room |> TableView.render(user_id) |> Jason.encode!()

  test "в снапшоте нет остатка колоды, seed RNG и резервов", %{room: room} do
    json = payload(room, "me")

    refute json =~ "deck"
    refute json =~ "rng"
    refute json =~ "seed"
    refute json =~ "reservation"
  end

  test "тайминги комнаты приходят в снапшоте, а не зашиты в клиент", %{room: room} do
    snapshot = TableView.render(room, "me")

    # Клиенту нечего хардкодить: и обычное время на ход, и потолок банка
    # принадлежат шаблону комнаты и в разных форматах разные.
    assert snapshot.timings.action_timeout_ms == room.setting.action_timeout_ms
    assert snapshot.timings.time_bank_ms == room.setting.time_bank_ms
    assert snapshot.timings.time_bank_refill == room.setting.time_bank_refill
    assert snapshot.timings.disconnect_grace_ms == room.setting.disconnect_grace_ms
    assert snapshot.timings.rebuy_prompt_ms == room.setting.rebuy_prompt_ms
  end

  test "чужой преселект в снапшот не попадает", %{room: room} do
    {:ok, room, _seat} = RoomState.set_preselect(room, "opponent", :fold)

    snapshot = TableView.render(room, "me")

    # Заранее выбранный фолд рассказал бы столу о руке раньше самого хода:
    # в чужих местах его нет ни в каком виде, а своё поле пустое.
    refute Jason.encode!(snapshot) =~ "fold"
    assert Enum.all?(snapshot.seats, &(not Map.has_key?(&1, :preselect)))
    assert snapshot.you.preselect == nil

    # Свой — виден: игрок должен видеть, что кнопка нажата.
    assert TableView.render(room, "opponent").you.preselect == :fold
  end

  test "показатели видны по каждому месту, включая чужое", %{room: room} do
    snapshot = TableView.render(room, "me")
    stats = Map.new(snapshot.seats, &{&1.seat, &1.stats})

    # Статистика публична: она выводится из действий, которые видел весь стол.
    assert stats[1].hands == 0
    assert stats[4].hands == 0
    # Пустой выборки нет — процента тоже нет.
    assert stats[4].vpip == nil
    assert Jason.encode!(snapshot) =~ "\"vpip\""
  end

  test "снапшот персональный: своё место помечено, чужое — нет", %{room: room} do
    mine = TableView.render(room, "me")
    theirs = TableView.render(room, "opponent")

    assert mine.you.seat == 1
    assert theirs.you.seat == 4

    # Список мест общий и одинаковый: скрывать в нём пока нечего.
    assert Enum.map(mine.seats, & &1.seat) == Enum.map(theirs.seats, & &1.seat)
  end

  test "место показывает ник и аватар: стол рисуется игроками, а не UUID", %{room: room} do
    snapshot = TableView.render(room, "me")
    villain = Enum.find(snapshot.seats, &(&1.seat == 4))

    assert villain.name == "Villain"
    assert villain.avatar == "/b.png"
  end

  test "карта уходит парой rank/suit, а не внутренним числом", %{room: room} do
    # Внутри ядра карта — целое ради скорости эквити; на границе с сокетом
    # она обязана стать %{rank, suit}, иначе клиент получит бессмысленное 18.
    event =
      TableView.event("button_draw", %{
        button_seat: 1,
        animation_ms: 3000,
        cards: [%{seat: 1, card: 18}, %{seat: 4, card: 4}]
      })

    assert event.cards == [
             %{seat: 1, card: %{rank: 6, suit: "D"}},
             %{seat: 4, card: %{rank: 3, suit: "S"}}
           ]

    # Событие без карт проходит насквозь и ничего не выдумывает.
    assert TableView.event("seat_left", %{room_id: room.room_id}) == %{room_id: room.room_id}
  end

  test "стеки и статусы видны всем — это публичная информация", %{room: room} do
    snapshot = TableView.render(room, "me")

    assert Enum.find(snapshot.seats, &(&1.seat == 4)).stack == 600
  end

  test "снапшот сериализуется без потерь и содержит косметику стола", %{room: room} do
    decoded = room |> payload("me") |> Jason.decode!()

    assert decoded["visuals"]["felt_color"]
    assert decoded["visuals"]["background_color"]
    assert decoded["max_players"] == 6
  end
end
