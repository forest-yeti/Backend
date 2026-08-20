defmodule Socket.Channels.ShowdownRevealTest do
  @moduledoc """
  Вскрытие на ривере глазами клиента. Отдельных событий показа карт нет:
  всё, на чём клиент рисует открытые руки, лежит внутри `hand_finished`,
  и поэтому проверяется именно состав этого сообщения.

  Проверка написана по жалобе «вскрытия в конце раздачи нет» и фиксирует
  границу: если руки перестанут доезжать до клиента, падать должно здесь.
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
    {:ok, %{token: token}} = BlockPoker.Accounts.start_session(user)
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    {:ok, _reply, channel} = subscribe_and_join(socket, "table:#{room_id}", %{})
    %{user: user, channel: channel}
  end

  defp room_pid(room_id), do: BlockPoker.Tables.TableRegistry.whereis(room_id)

  # Раздача разыгрывается чеками и коллами до самого конца.
  defp play(_channels, seen, steps) when steps > 400, do: Enum.reverse(seen)

  defp play(channels, seen, steps) do
    receive do
      # Подсказка приходит в оба сокета: ходим один раз за неё.
      %Phoenix.Socket.Message{event: "action_prompt", payload: prompt} ->
        already =
          Enum.any?(seen, fn
            {"action_prompt", seat, seq, _move} ->
              seat == prompt.seat and seq == prompt.action_seq

            _other ->
              false
          end)

        unless already do
          channel = Map.fetch!(channels, prompt.seat)
          move = if prompt.legal_actions.check, do: "check", else: "call"
          push(channel, "action", %{"type" => move, "action_seq" => prompt.action_seq})
        end

        move = if prompt.legal_actions.check, do: "check", else: "call"

        play(
          channels,
          [{"action_prompt", prompt.seat, prompt.action_seq, move} | seen],
          steps + 1
        )

      %Phoenix.Socket.Message{event: event, payload: payload} ->
        play(channels, [{event, payload} | seen], steps + 1)
    after
      1_500 -> Enum.reverse(seen)
    end
  end

  test "вскрытие на ривере доезжает до клиента", %{room_id: room_id, buy_in: buy_in} do
    %{channel: first} = connect_player(room_id)
    %{channel: second} = connect_player(room_id)

    ref = push(first, "join_seat", %{"seat" => 1, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload
    ref = push(second, "join_seat", %{"seat" => 2, "buy_in" => buy_in})
    assert_reply ref, :ok, _payload

    :ok = TableServer.fire_timer(room_pid(room_id), :button_draw)

    stream = play(%{1 => first, 2 => second}, [], 0)

    finished =
      Enum.find_value(stream, fn
        {"hand_finished", payload} -> payload
        _other -> nil
      end)

    assert finished, "hand_finished до клиента не доехал"

    assert finished.showdown, "раздача дошла до ривера, а showdown? = false"
    assert length(finished.shown) == 2, "на вскрытии обязаны открыться обе руки"
    assert Enum.all?(finished.shown, &(length(&1.cards) == 2))
    assert Enum.all?(finished.shown, &(&1.category != nil))
  end
end
