defmodule Socket.Channels.ThreeWayAllInTest do
  @moduledoc """
  Жалоба: трое в раздаче, двое идут олл-ин, третий коллирует — и у третьего
  клиент показывает «нет связи», хотя раздача доигрывается нормально.

  Проверяется путь целиком: ответ на его же `action` и все пуши, которые
  после этого обязаны до него дойти.
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
    %{room_id: room_id, pid: pid, buy_in: CashGameSetting.min_buy_in_chips(setting)}
  end

  defp connect_player(room_id) do
    user = user_fixture()
    {:ok, %{token: token}} = BlockPoker.Accounts.start_session(user)
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    {:ok, _reply, channel} = subscribe_and_join(socket, "table:#{room_id}", %{})
    %{user: user, channel: channel}
  end

  test "колл третьего подтверждается и его канал остаётся живым", ctx do
    %{room_id: room_id, pid: pid, buy_in: buy_in} = ctx

    players =
      for seat <- 1..3 do
        %{user: user, channel: channel} = connect_player(room_id)
        ref = push(channel, "join_seat", %{"seat" => seat, "buy_in" => buy_in, "entry" => "post"})
        assert_reply ref, :ok, _payload
        %{seat: seat, user: user, channel: channel}
      end

    :ok = TableServer.fire_timer(pid, :button_draw)

    # Двое идут олл-ин, третий коллирует — порядок берётся у стола, а не
    # угадывается: кнопка разыграна случайно.
    for step <- 1..3 do
      room = TableServer.state(pid)
      player = Enum.find(players, &(&1.seat == room.hand.to_act))
      action = if step == 3, do: "call", else: "all_in"

      ref = push(player.channel, "action", %{"type" => action})
      assert_reply ref, :ok, _payload, 2_000
    end

    room = TableServer.state(pid)
    assert room.hand.runout?, "торговля обязана закрыться после колла третьего"

    # Раздача доводится по улице за тик; каждый тик обязан дойти до всех.
    # Вскрытие обязано дойти до каждого из трёх каналов.
    for _player <- players, do: assert_push("all_in_showdown", _payload)

    Enum.reduce_while(1..10, :running, fn _step, _acc ->
      case TableServer.state(pid).hand do
        nil -> {:halt, :done}
        _hand -> {:cont, TableServer.fire_timer(pid, :runout)}
      end
    end)

    for player <- players do
      assert Process.alive?(player.channel.channel_pid),
             "канал игрока #{player.seat} упал за раздачу"
    end
  end
end
