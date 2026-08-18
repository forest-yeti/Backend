defmodule BlockPoker.GameMode.CashTest do
  @moduledoc """
  Политика кэш-игры между раздачами: рейк и сборка входа раздачи.
  Без БД — шаблон собирается в памяти.
  """

  use ExUnit.Case, async: true

  import BlockPoker.CashGamesFixtures

  alias BlockPoker.Engine.{Hand, HandSetup, Rng}
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
    room = seat(room, 1, "user-1", 400, :post)
    room = seat(room, 2, "user-2", 400, :post)
    room = seat(room, 3, "watcher", 400)
    {:ok, room} = RoomState.sit_out(room, "watcher")

    assert Cash.can_leave?(room, RoomState.find_seat(room, "user-1"))

    {:ok, setup} = Cash.hand_setup(room)
    {hand, _events} = Hand.start(setup, Rng.seeded("тест"))
    playing = %{room | phase: :hand, hand: hand}

    refute Cash.can_leave?(playing, RoomState.find_seat(playing, "user-1"))

    # Не участник раздачи столу ничем не обязан: сидящий мимо руки волен
    # встать, не дожидаясь её конца.
    assert Cash.can_leave?(playing, RoomState.find_seat(playing, "watcher"))
  end

  test "олл-ин не выпускает игрока из-за стола" do
    # Стек места на олл-ине равен нулю, и проверка «по стеку» считала такого
    # игрока непричастным к раздаче — он уходил, а выигранный банк оседал
    # на пустом месте.
    setting = build_setting(%{})
    room = RoomState.new(Ecto.UUID.generate(), setting)
    room = seat(room, 1, "user-1", 400, :post)
    room = seat(room, 2, "user-2", 400, :post)

    {:ok, setup} = Cash.hand_setup(room)
    {hand, _events} = Hand.start(setup, Rng.seeded("тест"))
    {:ok, hand, _events} = Hand.act(hand, hand.to_act, :all_in, nil)

    all_in = Enum.find(Map.values(hand.players), &(&1.stack == 0))
    room = %{room | phase: :hand, hand: hand}
    room = put_in(room.seats[all_in.seat].stack, 0)

    refute Cash.can_leave?(room, RoomState.find_seat(room, "user-#{all_in.seat}"))
  end

  test "сбросивший руку уходить может" do
    setting = build_setting(%{})
    room = RoomState.new(Ecto.UUID.generate(), setting)
    room = seat(room, 1, "user-1", 400, :post)
    room = seat(room, 2, "user-2", 400, :post)
    room = seat(room, 3, "user-3", 400, :post)

    {:ok, setup} = Cash.hand_setup(room)
    {hand, _events} = Hand.start(setup, Rng.seeded("тест"))
    folded_seat = hand.to_act
    {:ok, hand, _events} = Hand.act(hand, folded_seat, :fold, nil)

    room = %{room | phase: :hand, hand: hand}

    # На банк он больше не претендует — держать его за столом незачем.
    assert Cash.can_leave?(room, RoomState.find_seat(room, "user-#{folded_seat}"))
  end

  defp seat(room, number, user_id, stack, entry \\ :wait_bb) do
    reservation = "res-#{number}"
    {:ok, room} = RoomState.reserve(room, number, user_id, reservation)
    {:ok, room, _seat} = RoomState.confirm(room, reservation, stack, entry)
    room
  end
end
