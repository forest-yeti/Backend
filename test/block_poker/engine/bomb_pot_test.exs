defmodule BlockPoker.Engine.BombPotTest do
  @moduledoc """
  Бомб-пот на живой раздаче: взнос со всех, флоп сразу, торговля с флопа.

  Проверяется поведение, а не «сколько денег в банке»: кто платит, с какой
  улицы начинается раздача, кто говорит первым и сохраняются ли фишки.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BlockPoker.Engine.{BombPot, Hand, HandSetup, Rng}
  alias BlockPoker.Engine.Variant.TexasHoldem

  @ante 100

  defp setup_hand(stacks, opts) do
    players =
      stacks
      |> Enum.with_index(1)
      |> Enum.map(fn {stack, seat} ->
        %{seat: seat, id: "p#{seat}", stack: stack, post: 0, dead_post: 0}
      end)

    %HandSetup{
      variant: TexasHoldem,
      players: players,
      button_seat: Keyword.get(opts, :button, 1),
      small_blind: 5,
      big_blind: 10,
      bomb_pot: %{ante: Keyword.get(opts, :ante, @ante)}
    }
  end

  defp start(stacks, opts \\ []) do
    setup = setup_hand(stacks, opts)
    {hand, events} = Hand.start(setup, Rng.seeded(<<13::256>>))

    assert Hand.total_chips(hand) == HandSetup.total_chips(setup)

    {hand, events}
  end

  defp posted(events) do
    for {:posted, payload} <- events, do: {payload.seat, payload.kind, payload.amount}
  end

  defp act!(hand, seat, action) do
    {:ok, hand, _events} = Hand.act(hand, seat, action, nil)
    hand
  end

  describe "взнос" do
    test "платят все и поровну, блайндов нет" do
      {hand, events} = start([1_000, 1_000, 1_000], button: 1)

      # Порядок постановки — от кнопки по часовой стрелке, как за столом.
      assert posted(events) == [
               {2, "bomb_pot_ante", @ante},
               {3, "bomb_pot_ante", @ante},
               {1, "bomb_pot_ante", @ante}
             ]

      assert hand.pot == 3 * @ante
      assert Enum.all?(Map.values(hand.players), &(&1.total == @ante))
    end

    test "взнос больше стека — это олл-ин, а не долг" do
      {hand, _events} = start([1_000, 40, 1_000], button: 1)

      assert hand.players[2].stack == 0
      assert hand.players[2].status == :all_in
      assert hand.pot == @ante + 40 + @ante
    end
  end

  describe "раздача начинается с флопа" do
    test "флоп открыт, ставок круга нет, говорит ближайший от кнопки" do
      {hand, events} = start([1_000, 1_000, 1_000], button: 1)

      assert hand.street == :flop
      assert length(hand.board) == 3
      assert hand.bet == 0
      assert hand.to_act == 2

      # Номинал круга — большой блайнд стола, а не размер взноса: за банк
      # уже заплатили, и торговля идёт по обычной цене стола.
      assert hand.min_raise == 10

      assert [{:street_dealt, %{street: :flop}}] =
               Enum.filter(events, &match?({:street_dealt, _payload}, &1))

      # Префлопа не было: единственный prompt относится к флопу.
      assert [{:action_prompt, %{seat: 2}}] =
               Enum.filter(events, &match?({:action_prompt, _payload}, &1))
    end

    test "карманные карты розданы до флопа" do
      {hand, events} = start([1_000, 1_000], button: 1)

      assert Enum.all?(Map.values(hand.players), &(length(&1.hole) == 2))

      order = Enum.map(events, &elem(&1, 0))

      assert Enum.find_index(order, &(&1 == :hole_dealt)) <
               Enum.find_index(order, &(&1 == :street_dealt))
    end

    test "чек до ривера доводит раздачу до вскрытия" do
      {hand, _events} = start([1_000, 1_000], button: 1)

      hand =
        Enum.reduce(1..3, hand, fn _street, hand ->
          hand |> act!(2, :check) |> act!(1, :check)
        end)

      assert Hand.finished?(hand)
      assert length(hand.board) == 5
    end

    test "все короче взноса — борд доводится без торговли" do
      {hand, _events} = start([40, 60], button: 1, ante: @ante)

      assert hand.to_act == nil
      assert hand.runout?
    end
  end

  describe "бросок" do
    test "выключенный и стопроцентный шанс не трогают RNG" do
      rng = Rng.seeded(<<1::256>>)

      assert {false, ^rng} = BombPot.roll(rng, 0)
      assert {true, ^rng} = BombPot.roll(rng, BombPot.scale())
    end

    test "шанс соблюдается на длинной серии" do
      {count, _rng} =
        Enum.reduce(1..2_000, {0, Rng.seeded(<<42::256>>)}, fn _index, {count, rng} ->
          {bomb?, rng} = BombPot.roll(rng, 1_000)
          {count + if(bomb?, do: 1, else: 0), rng}
        end)

      # Ожидание — 200 при шансе 10%; границы взяты с большим запасом,
      # чтобы тест ловил сломанную шкалу, а не дисперсию.
      assert count in 130..270
    end

    property "бросок воспроизводится по seed" do
      check all(
              seed <- StreamData.binary(length: 32),
              chance <- StreamData.integer(0..BombPot.scale())
            ) do
        assert BombPot.roll(Rng.seeded(seed), chance) |> elem(0) ==
                 BombPot.roll(Rng.seeded(seed), chance) |> elem(0)
      end
    end
  end

  describe "подпись шанса" do
    test "десятитысячные превращаются в проценты" do
      assert BombPot.percent_label(500) == "5"
      assert BombPot.percent_label(10_000) == "100"
      assert BombPot.percent_label(250) == "2.5"
      assert BombPot.percent_label(125) == "1.25"
      assert BombPot.percent_label(5) == "0.05"
    end
  end

  describe "деньги" do
    property "фишки не возникают и не исчезают при любых стеках" do
      check all(
              stacks <- StreamData.list_of(StreamData.integer(1..2_000), length: 3),
              max_runs: 50
            ) do
        setup = setup_hand(stacks, button: 1)
        {hand, _events} = Hand.start(setup, Rng.seeded(<<77::256>>))

        assert Hand.total_chips(hand) == HandSetup.total_chips(setup)

        hand = check_down(hand)
        assert Hand.total_chips(hand) == HandSetup.total_chips(setup)
      end
    end
  end

  # Все живые чекают до конца раздачи.
  defp check_down(hand) do
    if Hand.finished?(hand) or hand.to_act == nil do
      hand
    else
      hand |> act!(hand.to_act, :check) |> check_down()
    end
  end
end
