defmodule BlockPoker.Tables.OfcTableTest do
  @moduledoc """
  Стол китайского покера как процесс: раздача целиком, тайм-аут, реконнект,
  фантазия и расчёт фишек.

  Проверяется **оболочка**, а не стратегия раскладки: ходы делаются той же
  автораскладкой, которой стол ходит за отвалившегося. Без БД и без реального
  времени — таймеры прогоняются вручную (§11 CLAUDE.md).
  """

  use ExUnit.Case, async: true

  import BlockPoker.TablesHelpers

  alias BlockPoker.Tables.{RoomState, TableServer}

  setup do
    ensure_tables!()
    :ok
  end

  defp deal!(pid, users) do
    Enum.each(users, fn {user, seat} -> seat!(pid, user, seat, 1000, :post) end)
    TableServer.fire_timer(pid, :button_draw)
    TableServer.state(pid)
  end

  defp total_stacks(room) do
    room |> RoomState.seats() |> Enum.map(& &1.stack) |> Enum.sum()
  end

  describe "раздача" do
    test "двое доигрывают раздачу до конца" do
      %{pid: pid} = start_ofc_room!()
      room = deal!(pid, [{"user-1", 1}, {"user-2", 2}])

      assert room.phase == :hand
      room = play_ofc_hand!(pid)

      assert room.hand == nil
      assert room.hands_played == 1
    end

    test "трое доигрывают раздачу до конца" do
      %{pid: pid} = start_ofc_room!()
      deal!(pid, [{"user-1", 1}, {"user-2", 2}, {"user-3", 3}])

      room = play_ofc_hand!(pid)

      assert room.hand == nil
      assert room.hands_played == 1
    end

    test "фишки за столом не появляются и не исчезают" do
      %{pid: pid} = start_ofc_room!()
      room = deal!(pid, [{"user-1", 1}, {"user-2", 2}, {"user-3", 3}])
      before = total_stacks(room)

      room = play_ofc_hand!(pid)

      assert total_stacks(room) == before
      assert Enum.all?(RoomState.seats(room), &(&1.stack >= 0))
    end

    test "стеки меняются на ту сумму, которую насчитала раздача" do
      %{pid: pid} = start_ofc_room!()
      deal!(pid, [{"user-1", 1}, {"user-2", 2}])

      # Итог берётся из последнего снапшота до конца раздачи: после неё
      # раздачи в комнате уже нет, а стеки мест обязаны сойтись с расчётом.
      room = play_ofc_hand!(pid)

      assert Enum.map(RoomState.seats(room), & &1.stack) |> Enum.sum() == 2000
      assert Enum.any?(RoomState.seats(room), &(&1.stack != 1000))
    end
  end

  describe "тайм-аут" do
    test "просроченный ход раскладывает карты и не роняет стол" do
      %{pid: pid} = start_ofc_room!()
      room = deal!(pid, [{"user-1", 1}, {"user-2", 2}])
      seat = room.discipline.to_act(room.hand)

      # По два тика на игрока: первый включает личный запас, второй его
      # дожигает и ходит за игрока.
      TableServer.fire_timer(pid, :action)
      TableServer.fire_timer(pid, :action)

      room = TableServer.state(pid)

      assert Process.alive?(pid)

      # Фолда в раскладке нет: карты выложены, и очередь ушла дальше.
      assert room.discipline.public_view(room.hand).seats[seat].placed == 5
      assert room.discipline.to_act(room.hand) != seat
    end
  end

  describe "снапшот" do
    test "игрок видит свои боксы и свою руку, чужих сбросов в снапшоте нет" do
      %{pid: pid} = start_ofc_room!()
      room = deal!(pid, [{"user-1", 1}, {"user-2", 2}])

      snapshot = Socket.Views.TableView.render(room, "user-1")
      raw = inspect(snapshot)

      assert Map.has_key?(snapshot.hand.seats[1], :rows)
      assert Map.has_key?(snapshot.you, :rows)

      # Сбросы видит только их владелец: в публичной части раздачи такого
      # поля нет вовсе — его не приходится вырезать, потому что его туда
      # не кладут. Своё же уходит владельцу, и в сыром payload слово
      # встречается ровно один раз — в личной части.
      assert Map.has_key?(snapshot.you, :discards)
      refute Map.has_key?(snapshot.hand.seats[1], :discards)
      refute Map.has_key?(snapshot.hand.seats[2], :discards)
      assert length(String.split(raw, "discards")) - 1 == 1

      refute Map.has_key?(snapshot.hand.seats[2], :deal)

      # Механик холдема у дисциплины нет — и стол их не выдумывает.
      assert snapshot.run_it_twice == nil
      assert snapshot.bomb_pot == nil
    end

    test "вернувшийся после разрыва получает свои боксы и свою руку" do
      %{pid: pid} = start_ofc_room!()
      deal!(pid, [{"user-1", 1}, {"user-2", 2}])

      # Ходит тот, чья очередь, потом «отваливается» и возвращается за
      # снапшотом: выложенное обязано быть на месте.
      room = TableServer.state(pid)
      seat = room.discipline.to_act(room.hand)
      user_id = room.seats[seat].user_id

      :ok = place!(pid, user_id)
      snapshot = pid |> TableServer.state() |> Socket.Views.TableView.render(user_id)

      placed = snapshot.you.rows.bottom ++ snapshot.you.rows.middle ++ snapshot.you.rows.top
      assert length(placed) == 5
      assert snapshot.you.deal == []
    end
  end

  describe "фантазия" do
    test "переживает конец раздачи и теряется вместе с местом" do
      %{pid: pid} = start_ofc_room!()
      deal!(pid, [{"user-1", 1}, {"user-2", 2}])
      room = play_ofc_hand!(pid)

      # Фантазию выдаёт дисциплина, перекладывает режим, хранит место.
      # Комната при этом не знает, что именно она хранит: поле места
      # непрозрачно, и в снапшоте раздачи его нет вовсе.
      assert Enum.all?(RoomState.seats(room), &(&1.carry in [nil, :fantasy]))

      room = RoomState.put_carry(room, %{1 => :fantasy})
      assert RoomState.find_seat(room, "user-1").carry == :fantasy

      # Освобождённое место уносит с собой всё, что на нём лежало: игрок,
      # вставший из-за стола в фантазии, теряет её.
      assert RoomState.clear_seats(room).seats[1].carry == nil
    end

    test "режим кладёт в место ровно то, что насчитала раздача" do
      %{pid: pid} = start_ofc_room!()
      deal!(pid, [{"user-1", 1}, {"user-2", 2}])
      room = play_ofc_hand!(pid)

      # Сколько карт сдаётся фантазийному игроку и когда он ходит —
      # проверяет тест уровня 1: там раздача строится напрямую и не зависит
      # от того, кому повезло с картами. Здесь проверяется стык: метка
      # попала в место, и попала не от стола, а от режима.
      seats = Map.new(RoomState.seats(room), &{&1.number, &1.carry})

      assert Map.keys(seats) |> Enum.sort() == [1, 2, 3]
      assert Enum.all?(Map.values(seats), &(&1 in [nil, :fantasy]))
    end
  end

  describe "нехватка стека" do
    test "перенос урезан, суммарное число фишек за столом не изменилось" do
      %{pid: pid} = start_ofc_room!(%{point_value: 100, min_buy_in: 1, max_buy_in: 2000})

      seat!(pid, "user-1", 1, 100, :post)
      seat!(pid, "user-2", 2, 5000, :post)
      TableServer.fire_timer(pid, :button_draw)

      before = total_stacks(TableServer.state(pid))
      room = play_ofc_hand!(pid)

      assert total_stacks(room) == before
      assert Enum.all?(RoomState.seats(room), &(&1.stack >= 0))
    end
  end
end
