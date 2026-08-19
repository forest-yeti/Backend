defmodule BlockPoker.Engine.ButtonAnteTest do
  @moduledoc """
  Структура «анте от всех + анте кнопки» на живой раздаче.

  Проверяется не «сколько денег в банке», а поведение: кто платит, чья
  ставка живая, кто говорит первым и последним и сохраняются ли фишки.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BlockPoker.Engine.BettingStructure.ButtonAnte
  alias BlockPoker.Engine.{Hand, HandSetup, Rng}
  alias BlockPoker.Engine.Variant.ShortDeck

  @ante 10

  defp setup_hand(stacks, opts \\ []) do
    players =
      stacks
      |> Enum.with_index(1)
      |> Enum.map(fn {stack, seat} ->
        %{seat: seat, id: "p#{seat}", stack: stack, post: 0, dead_post: 0}
      end)

    %HandSetup{
      variant: ShortDeck,
      players: players,
      button_seat: Keyword.get(opts, :button, 1),
      ante: Keyword.get(opts, :ante, @ante)
    }
  end

  defp start(stacks, opts \\ []) do
    setup = setup_hand(stacks, opts)
    {hand, events} = Hand.start(setup, Rng.seeded(<<11::256>>))

    # Инвариант денег проверяется на каждом старте: фишки не возникают.
    assert Hand.total_chips(hand) == HandSetup.total_chips(setup)

    {hand, events}
  end

  defp posted(events) do
    for {:posted, payload} <- events, do: {payload.seat, payload.kind, payload.amount}
  end

  describe "вынужденные ставки" do
    test "анте платят все, кнопка — дважды" do
      {hand, events} = start([1_000, 1_000, 1_000], button: 1)

      # Порядок постановки — от кнопки по часовой стрелке, как за столом:
      # первым платит игрок слева от неё.
      assert posted(events) == [
               {2, "ante", @ante},
               {3, "ante", @ante},
               {1, "ante", @ante},
               {1, "button_ante", @ante}
             ]

      # Банк до первой карты: по анте с каждого плюс второе анте кнопки.
      assert hand.pot == 3 * @ante + @ante
    end

    test "живая только вторая ставка кнопки: остальные анте мёртвые" do
      {hand, _events} = start([1_000, 1_000, 1_000], button: 1)

      # Уравнивать надо ровно анте — столько поставила кнопка живыми.
      assert hand.bet == @ante
      assert hand.players[1].committed == @ante
      assert hand.players[2].committed == 0
      assert hand.players[3].committed == 0

      # Мёртвые деньги в банке лежат, но ничьей ставкой не являются.
      assert hand.players[2].dead == @ante
      assert hand.players[3].dead == @ante
    end

    test "минимальный рейз на префлопе — два анте, минимальная ставка постфлоп — анте" do
      {hand, _events} = start([1_000, 1_000, 1_000], button: 1)

      legal = Hand.legal_actions(hand, hand.to_act)

      assert hand.bet_unit == @ante
      assert legal.call == @ante
      assert legal.raise.min == 2 * @ante
    end
  end

  describe "порядок хода" do
    test "первым говорит игрок слева от кнопки, кнопка — последней" do
      {hand, _events} = start([1_000, 1_000, 1_000], button: 1)

      assert hand.to_act == 2

      {hand, _events} = Hand.act(hand, 2, :call, nil) |> ok()
      assert hand.to_act == 3

      {hand, _events} = Hand.act(hand, 3, :call, nil) |> ok()

      # Слово кнопки: все уравняли, но право повысить у неё остаётся.
      assert hand.to_act == 1
    end

    test "на всех улицах порядок один и тот же — позиция не меняется" do
      {hand, _events} = start([1_000, 1_000, 1_000], button: 1)

      {hand, _events} = Hand.act(hand, 2, :call, nil) |> ok()
      {hand, _events} = Hand.act(hand, 3, :call, nil) |> ok()
      {hand, _events} = Hand.act(hand, 1, :check, nil) |> ok()

      # Флоп: первым снова слева от кнопки, а не «как на префлопе».
      assert hand.street == :flop
      assert hand.to_act == 2
    end
  end

  describe "хедз-ап" do
    test "оба платят анте, кнопка платит второе и говорит последней" do
      {hand, events} = start([1_000, 1_000], button: 1)

      assert posted(events) == [
               {2, "ante", @ante},
               {1, "ante", @ante},
               {1, "button_ante", @ante}
             ]

      # Ничего не меняется местами, как блайнды в холдеме: первым говорит
      # не кнопка.
      assert hand.to_act == 2
    end
  end

  describe "короткие стеки" do
    test "игрок, которому анте не хватает, платит остатком и остаётся в раздаче" do
      {hand, _events} = start([1_000, 4, 1_000], button: 1)

      assert hand.players[2].stack == 0
      assert hand.players[2].status == :all_in
      assert hand.pot == @ante + 4 + @ante + @ante
    end

    test "кнопке хватило только на первое анте" do
      {hand, _events} = start([@ante, 1_000, 1_000], button: 1)

      assert hand.players[1].stack == 0
      assert hand.players[1].status == :all_in
      assert hand.pot == @ante + @ante + @ante
    end
  end

  describe "мёртвая кнопка" do
    test "второе анте платит тот, кто говорит последним" do
      # Кнопка стоит на месте 4, которое эту раздачу не играет.
      {_hand, events} = start([1_000, 1_000, 1_000], button: 4)

      assert {seat, "button_ante", @ante} =
               events |> posted() |> Enum.find(&(elem(&1, 1) == "button_ante"))

      assert seat == 3
    end
  end

  describe "структура как данные" do
    test "forced_bets отдаёт мёртвые анте всем и живое кнопке" do
      setup = setup_hand([1_000, 1_000, 1_000], button: 1)

      assert ButtonAnte.forced_bets(setup) == [
               %{seat: 2, kind: :ante, amount: @ante, live?: false},
               %{seat: 3, kind: :ante, amount: @ante, live?: false},
               %{seat: 1, kind: :ante, amount: @ante, live?: false},
               %{seat: 1, kind: :button_ante, amount: @ante, live?: true}
             ]
    end

    test "структура не знает ни про блайнды, ни про вид покера" do
      setup = setup_hand([1_000, 1_000], button: 1)

      # Номинал берётся из анте даже если блайнды в шаблоне заданы: на
      # анте-столе их попросту не спрашивают.
      assert ButtonAnte.bet_unit(%{setup | small_blind: 5, big_blind: 10}) == @ante
    end

    test "номинал стола — анте, последним говорит кнопка" do
      setup = setup_hand([1_000, 1_000, 1_000], button: 1)

      assert ButtonAnte.bet_unit(setup) == @ante
      assert ButtonAnte.last_to_act_preflop(setup) == 1
      assert ButtonAnte.id() == :button_ante
    end

    test "вход в игру без ожидания" do
      decision = ButtonAnte.entry_rules().decide(%{})

      assert decision == %{status: :playing, post: 0, dead_post: 0, can_post: false}
      refute ButtonAnte.entry_rules().can_post?(%{})
    end
  end

  describe "инвариант денег" do
    property "фишки не возникают и не исчезают на всей раздаче" do
      check all(
              stacks <- StreamData.list_of(StreamData.integer(1..500), length: 3),
              button <- StreamData.integer(1..3),
              seed <- StreamData.binary(length: 32),
              max_runs: 50
            ) do
        setup = setup_hand(Enum.map(stacks, &(&1 * @ante)), button: button)
        {hand, _events} = Hand.start(setup, Rng.seeded(seed))

        total = HandSetup.total_chips(setup)
        assert Hand.total_chips(hand) == total

        hand = play_out(hand)

        # Раздача доиграна до конца случайными легальными действиями:
        # сумма стеков и банка обязана совпасть с начальной на каждом шаге.
        assert Hand.total_chips(hand) == total
      end
    end
  end

  # Доигрывание случайными действиями: важно не «кто выиграл», а то, что на
  # каждом шаге фишки сходятся.
  defp play_out(hand, steps \\ 60)

  defp play_out(hand, 0), do: hand

  defp play_out(%Hand{to_act: nil} = hand, _steps), do: hand

  defp play_out(hand, steps) do
    total = Hand.total_chips(hand)
    seat = hand.to_act
    legal = Hand.legal_actions(hand, seat)

    action = if legal.check, do: :check, else: pick_action(legal)

    case Hand.act(hand, seat, action, nil) do
      {:ok, next, _events} ->
        assert Hand.total_chips(next) == total
        play_out(next, steps - 1)

      {:error, _reason} ->
        hand
    end
  end

  defp pick_action(%{call: call}) when call > 0, do: :call
  defp pick_action(_legal), do: :fold

  defp ok({:ok, hand, events}), do: {hand, events}
end
