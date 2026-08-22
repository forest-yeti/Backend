defmodule Socket.Channels.OfcChannelTest do
  @moduledoc """
  Стол китайского покера глазами клиента: путь целиком, от payload до пуша.

  Топик у стола общий — `table:<uuid>`: раздельная у OFC только витрина.
  Проверяется, что через тот же канал и тот же `join_seat` играется другая
  дисциплина, и что отклонённая раскладка не меняет состояние стола.
  """

  use Socket.ChannelCase, async: false

  import BlockPoker.AccountsFixtures
  import BlockPoker.OfcGamesFixtures
  import BlockPoker.TablesHelpers

  alias BlockPoker.Engine.Card
  alias BlockPoker.OfcGames.OfcSetting
  alias BlockPoker.Tables.TableServer
  alias Ecto.Adapters.SQL.Sandbox
  alias Socket.UserSocket

  setup do
    ensure_tables!()
    setting = setting_fixture(%{currency: :play_money, max_players: 3, point_value: 10})
    room_id = Ecto.UUID.generate()

    pid =
      start_supervised!(
        {TableServer,
         [
           room_id: room_id,
           setting: setting,
           game_mode: BlockPoker.GameMode.OfcCash,
           discipline: BlockPoker.Engine.Ofc.Hand,
           timers: :manual
         ]},
        id: room_id
      )

    Sandbox.allow(BlockPoker.Repo, self(), pid)
    %{room_id: room_id, pid: pid, buy_in: OfcSetting.min_buy_in_chips(setting)}
  end

  defp connect_player(room_id) do
    user = user_fixture()
    {:ok, %{token: token}} = BlockPoker.Accounts.start_session(user)
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    {:ok, _reply, channel} = subscribe_and_join(socket, "table:#{room_id}", %{})
    %{user: user, channel: channel}
  end

  defp seat_players(%{room_id: room_id, pid: pid, buy_in: buy_in}, count) do
    players =
      Enum.map(1..count, fn seat ->
        player = connect_player(room_id)
        ref = push(player.channel, "join_seat", %{"seat" => seat, "buy_in" => buy_in})
        assert_reply ref, :ok, _payload
        Map.put(player, :seat, seat)
      end)

    :ok = TableServer.fire_timer(pid, :button_draw)
    players
  end

  # Раскладка текущего ходящего: карты берутся из его личного снапшота,
  # размещение выбирает та же автораскладка, которой ходит стол.
  defp place_payload(pid) do
    room = TableServer.state(pid)
    seat = room.discipline.to_act(room.hand)

    %{deal: {:cards, cards}, legal_actions: legal} =
      room.discipline.private_view(room.hand, seat)

    board = ofc_board_of(room, seat)

    {placements, discard} =
      BlockPoker.Engine.Ofc.Autoplace.choose(board, cards, legal.discard, room.hand.context)

    payload = %{
      "placements" =>
        Enum.map(placements, fn {card, row} ->
          %{"card" => Card.to_map(card), "row" => Atom.to_string(row)}
        end),
      "discard" => discard && Card.to_map(discard),
      "action_seq" => room.action_seq
    }

    {seat, payload}
  end

  defp ofc_board_of(room, seat) do
    alias BlockPoker.Engine.Ofc.Board

    %{rows: rows} = room.discipline.public_view(room.hand).seats[seat]

    Enum.reduce(Board.rows(), Board.new(), fn row, board ->
      {:cards, cards} = rows[row]
      Map.put(board, row, cards)
    end)
  end

  defp channel_of(players, seat), do: Enum.find(players, &(&1.seat == seat)).channel

  defp play_out(pid, players) do
    room = TableServer.state(pid)

    if room.hand && room.discipline.to_act(room.hand) do
      {seat, payload} = place_payload(pid)
      ref = push(channel_of(players, seat), "place_cards", payload)
      assert_reply ref, :ok, _reply
      play_out(pid, players)
    else
      room
    end
  end

  describe "раздача через сокет" do
    test "снапшот называет дисциплину", %{room_id: room_id} do
      user = user_fixture()
      {:ok, %{token: token}} = BlockPoker.Accounts.start_session(user)
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      # По этому полю клиент выбирает игровой экран: у китайского покера
      # нет ни борда, ни банка, и открыть под него окно холдема нельзя.
      assert {:ok, snapshot, _channel} = subscribe_and_join(socket, "table:#{room_id}", %{})
      assert snapshot.discipline == :ofc_pineapple
    end

    test "двое играют раздачу целиком", context do
      players = seat_players(context, 2)
      room = play_out(context.pid, players)

      assert room.hand == nil
      assert room.hands_played == 1
    end

    test "трое играют раздачу целиком, фишки за столом не меняются", context do
      players = seat_players(context, 3)

      before =
        context.pid
        |> TableServer.state()
        |> BlockPoker.Tables.RoomState.seats()
        |> Enum.map(& &1.stack)
        |> Enum.sum()

      room = play_out(context.pid, players)

      total =
        room |> BlockPoker.Tables.RoomState.seats() |> Enum.map(& &1.stack) |> Enum.sum()

      assert total == before
      assert room.hands_played == 1
    end
  end

  describe "отклонение раскладки" do
    test "чужая карта, переполненный бокс и неверное число размещений", context do
      players = seat_players(context, 2)
      {seat, payload} = place_payload(context.pid)
      channel = channel_of(players, seat)
      seq_before = TableServer.state(context.pid).action_seq

      # Карта не из сдачи.
      alien = %{"card" => alien_card(context.pid, seat), "row" => "bottom"}
      broken = %{payload | "placements" => [alien | tl(payload["placements"])]}
      ref = push(channel, "place_cards", broken)
      assert_reply ref, :error, %{code: "invalid_placement"}

      # Все пять карт в верхний бокс: он держит три.
      overflow = %{
        payload
        | "placements" => Enum.map(payload["placements"], &Map.put(&1, "row", "top"))
      }

      ref = push(channel, "place_cards", overflow)
      assert_reply ref, :error, %{code: "invalid_placement"}

      # Размещений меньше, чем требует сдача.
      short = %{payload | "placements" => Enum.take(payload["placements"], 2)}
      ref = push(channel, "place_cards", short)
      assert_reply ref, :error, %{code: "invalid_placement"}

      # Ни одна из отклонённых попыток стол не сдвинула.
      assert TableServer.state(context.pid).action_seq == seq_before
    end

    test "повтор того же action_seq — no-op", context do
      players = seat_players(context, 2)
      {seat, payload} = place_payload(context.pid)
      channel = channel_of(players, seat)

      ref = push(channel, "place_cards", payload)
      assert_reply ref, :ok, _reply

      seq = TableServer.state(context.pid).action_seq

      # Тот же ход с тем же счётчиком второй раз не проходит: счётчик стола
      # уже другой, и раскладка не удваивается.
      ref = push(channel, "place_cards", payload)
      assert_reply ref, :error, _error

      assert TableServer.state(context.pid).action_seq == seq
    end
  end

  describe "приватность" do
    test "в снапшоте соседа нет ни чужой руки, ни чьих-либо сбросов", context do
      players = seat_players(context, 2)
      [first | _rest] = players

      ref = push(first.channel, "table_state", %{})
      assert_reply ref, :ok, snapshot

      # Своя рука у владельца места есть, а у чужого места поля `deal` нет
      # вовсе: его не приходится вырезать, потому что его туда не кладут.
      assert Map.has_key?(snapshot.you, :deal)
      assert Enum.all?(Map.values(snapshot.hand.seats), &(not Map.has_key?(&1, :deal)))

      # Сбросы наружу уходят **числом**, а не картами: сколько игрок сбросил,
      # стол видит, а что именно — не видит никто, включая его самого.
      assert Enum.all?(Map.values(snapshot.hand.seats), &is_integer(&1.discarded))
      refute Enum.any?(Map.values(snapshot.hand.seats), &Map.has_key?(&1, :discards))
    end
  end

  defp alien_card(pid, seat) do
    room = TableServer.state(pid)
    %{deal: {:cards, cards}} = room.discipline.private_view(room.hand, seat)

    0..51 |> Enum.find(&(&1 not in cards)) |> Card.to_map()
  end
end
