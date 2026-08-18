defmodule BlockPoker.GameMode.CashTest do
  @moduledoc """
  Политика кэш-игры между раздачами: рейк и сборка входа раздачи.
  Без БД — шаблон собирается в памяти.
  """

  use ExUnit.Case, async: true

  import BlockPoker.CashGamesFixtures

  alias BlockPoker.Engine.HandSetup
  alias BlockPoker.Engine.Variant.TexasHoldem
  alias BlockPoker.GameMode.Cash
  alias BlockPoker.Tables.RoomState

  describe "рейк" do
    test "берётся процентом от банка" do
      setting = build_setting(%{currency: :main, rake_percent: 500})

      # 500 = 5%; хранение в сотых долях процента избавляет от float.
      assert Cash.rake(setting, 1000, 6) == 50
    end

    test "ограничивается потолком по числу игроков" do
      setting =
        build_setting(%{
          currency: :main,
          rake_percent: 500,
          rake_cap_by_players: %{"2" => 100, "5" => 300}
        })

      assert Cash.rake(setting, 100_000, 2) == 100
      assert Cash.rake(setting, 100_000, 6) == 300
    end

    test "на play_money не берётся никогда, даже если поля заполнены" do
      setting =
        build_setting(%{
          currency: :play_money,
          rake_percent: 500,
          rake_cap_by_players: %{"2" => 100}
        })

      assert Cash.rake(setting, 100_000, 6) == 0
    end

    test "no_flop_no_drop: без флопа рейка нет" do
      setting = build_setting(%{currency: :main, rake_percent: 500, no_flop_no_drop: true})

      assert Cash.rake(setting, 1000, 3, saw_flop?: false) == 0
      assert Cash.rake(setting, 1000, 3, saw_flop?: true) == 50
    end

    test "при выключенном no_flop_no_drop рейк берётся и до флопа" do
      setting = build_setting(%{currency: :main, rake_percent: 500, no_flop_no_drop: false})

      assert Cash.rake(setting, 1000, 3, saw_flop?: false) == 50
    end
  end

  describe "hand_setup" do
    setup do
      setting = build_setting(%{small_blind: 5, big_blind: 10, max_players: 6})
      %{room: RoomState.new(Ecto.UUID.generate(), setting)}
    end

    test "меньше двух игроков — раздачи нет", %{room: room} do
      assert {:error, :not_enough_players} = Cash.hand_setup(room)
    end

    test "блайнды приходят числами, а не ссылкой на шаблон", %{room: room} do
      room = seat(room, 1, "user-1", 400)
      room = seat(room, 4, "user-2", 400)
      room = %{room | button_seat: 1}

      {:ok, setup} = Cash.hand_setup(room)

      assert %HandSetup{variant: TexasHoldem, small_blind: 5, big_blind: 10} = setup
      assert Enum.map(setup.players, & &1.seat) == [1, 4]
      assert HandSetup.total_chips(setup) == 800
    end

    test "ждущий большого блайнда в раздачу не попадает", %{room: room} do
      room = seat(room, 1, "user-1", 400)
      room = seat(room, 4, "user-2", 400)
      room = %{room | button_seat: 1, big_blind_seat: 4}
      room = seat(room, 6, "user-3", 400, :wait_bb)

      {:ok, setup} = Cash.hand_setup(room)

      refute 6 in Enum.map(setup.players, & &1.seat)
    end
  end

  test "уход разрешён между раздачами и запрещён участнику текущей" do
    setting = build_setting(%{})
    room = RoomState.new(Ecto.UUID.generate(), setting)
    room = seat(room, 1, "user-1", 400)
    seat = RoomState.find_seat(room, "user-1")

    assert Cash.can_leave?(room, seat)
    refute Cash.can_leave?(%{room | phase: :hand}, seat)
  end

  defp seat(room, number, user_id, stack, entry \\ :wait_bb) do
    reservation = "res-#{number}"
    {:ok, room} = RoomState.reserve(room, number, user_id, reservation)
    {:ok, room, _seat} = RoomState.confirm(room, reservation, stack, entry)
    room
  end
end
