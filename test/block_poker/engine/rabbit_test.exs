defmodule BlockPoker.Engine.RabbitTest do
  @moduledoc """
  Rabbit hunting как чистое правило: что показывается, а главное — когда
  показывать нечего.

  Ключевой инвариант здесь один: показанные карты — это голова той же
  колоды, что была стасована в начале раздачи. Никакой новой случайности
  показ не вносит, поэтому его нельзя использовать, чтобы что-то узнать
  о будущей раздаче.
  """

  use ExUnit.Case, async: true

  alias BlockPoker.Engine.{Card, Hand, HandSetup, Rabbit, Rng}
  alias BlockPoker.Engine.Variant.TexasHoldem

  defp start(stacks) do
    players =
      stacks
      |> Enum.with_index(1)
      |> Enum.map(fn {stack, seat} ->
        %{seat: seat, id: "p#{seat}", stack: stack, post: 0, dead_post: 0}
      end)

    setup = %HandSetup{
      variant: TexasHoldem,
      players: players,
      button_seat: 1,
      small_blind: 5,
      big_blind: 10,
      ante: 0,
      ante_type: :big_blind
    }

    {hand, _events} = Hand.start(setup, Rng.seeded(<<7::256>>))
    hand
  end

  defp act(hand, action) do
    {:ok, hand, _events} = Hand.act(hand, hand.to_act, action, nil)
    hand
  end

  # Доигрывает до первого фолда на нужной улице: все чекают, пока улица
  # не сменится, затем один сбрасывает.
  defp check_to(hand, street) do
    if hand.street == street do
      hand
    else
      hand |> act(:check) |> check_to(street)
    end
  end

  describe "раздача, законченная фолдом" do
    test "на префлопе показывается весь борд тремя улицами" do
      hand = [400, 400] |> start() |> act(:fold)

      assert {:ok, [flop, turn, river]} = Rabbit.runout(hand)
      assert flop.street == :flop
      assert length(flop.cards) == 3
      assert turn.street == :turn
      assert length(turn.cards) == 1
      assert river.street == :river
      assert length(river.cards) == 1
    end

    test "на флопе показываются только тёрн и ривер" do
      hand = [400, 400] |> start() |> act(:call) |> act(:check) |> check_to(:flop) |> act(:fold)

      assert {:ok, [turn, river]} = Rabbit.runout(hand)
      assert turn.street == :turn
      assert river.street == :river
    end

    test "показываются ровно карты с головы стасованной колоды" do
      hand = [400, 400] |> start()
      deck = hand.deck
      folded = act(hand, :fold)

      assert {:ok, streets} = Rabbit.runout(folded)
      shown = Enum.flat_map(streets, & &1.cards)

      assert shown == deck |> Enum.take(5) |> Enum.map(&Card.to_map/1)
    end

    test "показанные карты не пересекаются с картами игроков и бордом" do
      hand = [400, 400] |> start() |> act(:call) |> act(:check) |> check_to(:flop) |> act(:fold)

      {:ok, streets} = Rabbit.runout(hand)
      shown = streets |> Enum.flat_map(& &1.cards) |> MapSet.new()

      known =
        hand.players
        |> Enum.flat_map(fn {_seat, player} -> player.hole end)
        |> Enum.concat(hand.board)
        |> MapSet.new(&Card.to_map/1)

      assert MapSet.disjoint?(shown, known)
    end
  end

  describe "показывать нечего" do
    test "идущая раздача — отказ" do
      assert {:error, :hand_in_progress} = Rabbit.runout(start([400, 400]))
    end

    test "после вскрытия — отказ" do
      hand =
        [400, 400]
        |> start()
        |> act(:call)
        |> act(:check)
        |> check_to(:flop)
        |> check_to(:turn)
        |> check_to(:river)
        |> check_to(:complete)

      assert hand.results.showdown?
      assert {:error, :showdown} = Rabbit.runout(hand)
    end

    test "фолд на ривере: борд полон, показывать нечего" do
      hand =
        [400, 400]
        |> start()
        |> act(:call)
        |> act(:check)
        |> check_to(:flop)
        |> check_to(:turn)
        |> check_to(:river)
        |> act(:fold)

      assert {:error, :board_complete} = Rabbit.runout(hand)
    end
  end
end
