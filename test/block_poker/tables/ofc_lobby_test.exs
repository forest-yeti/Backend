defmodule BlockPoker.Tables.OfcLobbyTest do
  @moduledoc """
  Витрина китайского покера: отдельная категория и отдельный топик.

  Главное продуктовое требование задачи — OFC-столы **не подмешиваются** к
  кэшу: подписчик `lobby` о них не узнаёт вовсе. Пул комнат при этом общий,
  и поднимает их тот же процесс тем же кодом.
  """

  use BlockPoker.DataCase, async: false

  import BlockPoker.OfcGamesFixtures
  import BlockPoker.TablesHelpers

  alias BlockPoker.Tables
  alias BlockPoker.Tables.Lobby
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
    :ok = Lobby.reload(name)
    name
  end

  defp snapshot(lobby, category) do
    {:ok, query} = Tables.lobby_query(nil, category)
    Lobby.snapshot(lobby, query)
  end

  test "шаблон китайского покера разворачивает комнату тем же пулом" do
    setting = setting_fixture(%{point_value: 10})
    lobby = start_lobby!()

    assert [room] = Lobby.rooms_for(lobby, setting.id)
    assert room.max_players == setting.max_players
    assert room.category == :ofc
  end

  test "OFC-столов нет в кэш-витрине, а кэш-столов — в OFC-витрине" do
    ofc = setting_fixture(%{point_value: 10})

    cash =
      BlockPoker.CashGamesFixtures.setting_fixture(%{
        currency: :play_money,
        small_blind: 5,
        big_blind: 10
      })

    lobby = start_lobby!()

    ofc_ids = lobby |> snapshot(:ofc) |> Enum.map(& &1.setting.id)
    cash_ids = lobby |> snapshot(:cash) |> Enum.map(& &1.setting.id)

    assert ofc.id in ofc_ids
    refute ofc.id in cash_ids

    assert cash.id in cash_ids
    refute cash.id in ofc_ids
  end

  test "обновления раздела уходят в его собственный топик" do
    setting = setting_fixture(%{point_value: 10})

    :ok = Phoenix.PubSub.subscribe(BlockPoker.PubSub, Lobby.topic(:ofc))
    :ok = Phoenix.PubSub.subscribe(BlockPoker.PubSub, Lobby.topic(:cash))

    lobby = start_lobby!()
    [room] = Lobby.rooms_for(lobby, setting.id)

    seat!(room.pid, "user-1", 1, 500)

    assert_receive {:lobby_update, %{setting: %{id: id}, category: :ofc}}
    assert id == setting.id

    # В кэш-топик про этот стол не уходит ничего.
    refute_receive {:lobby_update, %{setting: %{id: ^id}, category: :cash}}
  end

  test "витрина отдаёт лимит стоимостью очка, а не блайндами" do
    setting_fixture(%{point_value: 25, max_players: 2})
    lobby = start_lobby!()

    [row] = lobby |> snapshot(:ofc) |> Enum.map(&Socket.Views.OfcLobbyView.setting/1)

    assert row.point_value == 25
    assert row.bet_unit == 25
    assert row.discipline == :ofc_pineapple
    assert row.table_size == :heads_up
    refute Map.has_key?(row, :big_blind)
  end
end
