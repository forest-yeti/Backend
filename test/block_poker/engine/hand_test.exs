defmodule BlockPoker.Engine.HandTest do
  @moduledoc """
  Ход раздачи целиком. Главное, что здесь проверяется, — инвариант денег:
  сколько фишек вошло в раздачу, столько из неё и вышло, при любом сценарии.
  """

  use ExUnit.Case, async: true

  alias BlockPoker.Engine.{Hand, HandSetup, Rng}
  alias BlockPoker.Engine.Variant.TexasHoldem

  defp setup_hand(stacks, opts \\ []) do
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
      ante: Keyword.get(opts, :ante, 0),
      ante_type: Keyword.get(opts, :ante_type, :big_blind)
    }
  end

  defp start(stacks, opts \\ []) do
    setup = setup_hand(stacks, opts)
    {hand, events} = Hand.start(setup, Rng.seeded(<<7::256>>))
    assert Hand.total_chips(hand) == HandSetup.total_chips(setup)
    {hand, events}
  end

  defp act!(hand, seat, action) do
    {:ok, hand, events} = Hand.act(hand, seat, action, nil)
    {hand, events}
  end

  describe "мёртвая кнопка" do
    test "кнопка на месте, которое не играет раздачу, не роняет движок" do
      # Живой сценарий: третий игрок сидит в ожидании большого блайнда,
      # кнопка по кругу дошла до него, а раздачу играют двое. Кнопка при
      # этом «мёртвая» — среди игроков раздачи её места нет.
      {hand, events} = start([1000, 1000], button: 3)

      assert Hand.total_chips(hand) == 2000
      assert length(hand.order) == 2

      # Блайнды всё равно поставлены, и поставлены участниками раздачи.
      posted = for {:posted, payload} <- events, do: {payload.seat, payload.kind}
      assert [{small, "small_blind"}, {big, "big_blind"}] = posted
      assert small in hand.order
      assert big in hand.order
      assert small != big
    end
  end

  defp play_to_showdown(hand) do
    Enum.reduce_while(1..40, hand, fn _step, acc ->
      cond do
        Hand.finished?(acc) ->
          {:halt, acc}

        # Ставить некому: борд доводится шагами, как это делает стол.
        acc.runout? ->
          {:ok, acc, _events} = Hand.deal_next(acc)
          {:cont, acc}

        true ->
          seat = acc.to_act
          legal = Hand.legal_actions(acc, seat)
          action = if legal.check, do: :check, else: :call
          {acc, _events} = act!(acc, seat, action)
          {:cont, acc}
      end
    end)
  end

  test "блайнды ставятся, карты сдаются, ход у первого после большого блайнда" do
    {hand, events} = start([1000, 1000, 1000])

    posts = for {:posted, payload} <- events, do: {payload.seat, payload.kind, payload.amount}
    assert posts == [{2, "small_blind", 5}, {3, "big_blind", 10}]

    assert hand.pot == 15
    assert Enum.all?(Map.values(hand.players), &(length(&1.hole) == 2))

    # UTG на троих — кнопка: после большого блайнда круг замыкается на неё.
    assert hand.to_act == 1
    assert [{:action_prompt, prompt}] = Enum.filter(events, &match?({:action_prompt, _}, &1))
    assert prompt.to_call == 10
  end

  test "на хедз-апе кнопка ставит малый блайнд и говорит первой" do
    {hand, _events} = start([1000, 1000], button: 1)

    assert hand.players[1].committed == 5
    assert hand.players[2].committed == 10
    assert hand.to_act == 1
  end

  test "большой блайнд получает слово, даже когда все уравняли" do
    {hand, _events} = start([1000, 1000, 1000])
    {hand, _} = act!(hand, 1, :call)
    {hand, _} = act!(hand, 2, :call)

    assert hand.to_act == 3
    assert Hand.legal_actions(hand, 3).check
  end

  test "все сбросили — банк уходит последнему, вскрытия нет" do
    {hand, _events} = start([1000, 1000, 1000])
    {hand, _} = act!(hand, 1, :fold)
    {hand, _} = act!(hand, 2, :fold)

    assert Hand.finished?(hand)
    assert hand.results.showdown? == false
    assert hand.results.payouts == %{3 => 15}
    assert hand.players[3].stack == 1005
    assert Hand.total_chips(hand) == 3000
  end

  test "рука доходит до вскрытия, банк делится, фишки сохраняются" do
    {hand, _events} = start([1000, 1000])
    hand = play_to_showdown(hand)

    assert Hand.finished?(hand)
    assert hand.street == :complete
    assert length(hand.board) == 5
    assert hand.results.showdown?

    assert Enum.sum(Map.values(hand.results.payouts)) ==
             Enum.sum(Enum.map(hand.results.pots, & &1.amount))

    assert Hand.total_chips(hand) == 2000
  end

  test "мин-рейз соблюдается, недобор отвергается" do
    {hand, _events} = start([1000, 1000, 1000])

    assert Hand.legal_actions(hand, 1).raise == %{min: 20, max: 1000}
    assert {:error, :illegal_action} = Hand.act(hand, 1, {:raise, 15}, nil)

    {hand, _} = act!(hand, 1, {:raise, 30})
    assert hand.bet == 30

    # Следующий рейз — не меньше чем на величину прошлого повышения.
    assert Hand.legal_actions(hand, 2).raise.min == 50
  end

  test "рейз переоткрывает торговлю уже сказавшим игрокам" do
    {hand, _events} = start([1000, 1000, 1000])
    {hand, _} = act!(hand, 1, :call)
    {hand, _} = act!(hand, 2, {:raise, 40})

    assert hand.to_act == 3
    {hand, _} = act!(hand, 3, :call)

    # Первый уже уравнивал 10, но после рейза обязан ответить снова.
    assert hand.to_act == 1
    assert Hand.legal_actions(hand, 1).call == 30
  end

  test "короткий олл-ин не поднимает ставку и не переоткрывает торговлю" do
    # Короткий стек на малом блайнде: ему ответить нечем, кроме олл-ина.
    {hand, _events} = start([1000, 12, 1000], button: 1)
    {hand, _} = act!(hand, 1, {:raise, 100})
    {hand, _} = act!(hand, 2, :all_in)

    assert hand.players[2].status == :all_in
    assert hand.bet == 100
  end

  test "сайд-пот: короткий стек не забирает больше, чем внёс" do
    # Короткий олл-ин на 100 против двух глубоких: основной банк ограничен им.
    {hand, _events} = start([100, 1000, 1000], button: 3)
    {hand, _} = act!(hand, 3, :fold)
    {hand, _} = act!(hand, 1, :all_in)
    {hand, _} = act!(hand, 2, :call)

    hand = play_to_showdown(hand)

    assert Hand.finished?(hand)
    assert Map.get(hand.results.payouts, 1, 0) <= 200

    assert Enum.sum(Map.values(hand.results.payouts)) ==
             Enum.sum(Enum.map(hand.results.pots, & &1.amount))

    assert Hand.total_chips(hand) == 2100
  end

  test "олл-ин открывает карты, считает шансы и доводит борд по улице за шаг" do
    {hand, _events} = start([200, 200], button: 1)
    {hand, _} = act!(hand, 1, :all_in)
    {_hand, events} = act!(hand, 2, :call)

    # Ставить больше некому — карты открыты сразу, борд ещё пуст.
    assert [{:all_in_showdown, payload}] = Enum.filter(events, &match?({:all_in_showdown, _}, &1))
    assert length(payload.players) == 2
    assert Enum.all?(payload.players, &(length(&1.cards) == 2))
    assert payload.board == []

    assert length(payload.equity) == 2
    assert_in_delta Enum.sum(Enum.map(payload.equity, & &1.equity)), 1.0, 0.001
  end

  test "доводка борда идёт по одной улице и заканчивается вскрытием" do
    {hand, _events} = start([200, 200], button: 1)
    {hand, _} = act!(hand, 1, :all_in)
    {hand, _} = act!(hand, 2, :call)

    assert hand.runout?
    assert hand.to_act == nil

    {:ok, hand, _} = Hand.deal_next(hand)
    assert hand.street == :flop and length(hand.board) == 3

    {:ok, hand, _} = Hand.deal_next(hand)
    assert hand.street == :turn and length(hand.board) == 4

    {:ok, hand, _} = Hand.deal_next(hand)
    assert hand.street == :river and length(hand.board) == 5
    refute Hand.finished?(hand)

    {:ok, hand, events} = Hand.deal_next(hand)
    assert Hand.finished?(hand)
    assert Enum.any?(events, &match?({:hand_finished, _}, &1))
    assert Hand.total_chips(hand) == 400
  end

  test "время вышло: бесплатно — чек, иначе фолд" do
    {hand, _events} = start([1000, 1000, 1000])
    {:ok, folded, _} = Hand.timeout(hand)
    assert folded.players[1].status == :folded

    {hand, _} = act!(hand, 1, :call)
    {hand, _} = act!(hand, 2, :call)
    {:ok, checked, _} = Hand.timeout(hand)
    assert checked.street == :flop
  end

  test "устаревший action_seq отвергается — защита от даблклика" do
    {hand, _events} = start([1000, 1000, 1000])
    assert {:error, :stale_action} = Hand.act(hand, 1, :call, hand.seq + 5)
    assert {:ok, _hand, _events} = Hand.act(hand, 1, :call, hand.seq)
  end

  test "чужой ход отвергается" do
    {hand, _events} = start([1000, 1000, 1000])
    assert {:error, :not_your_turn} = Hand.act(hand, 2, :call, nil)
  end

  test "сбросивший может открыть карты по желанию" do
    {hand, _events} = start([1000, 1000, 1000])
    {hand, _} = act!(hand, 1, :fold)

    {:ok, hand, [{:cards_shown, payload}]} = Hand.show_cards(hand, 1)
    assert length(payload.cards) == 2
    assert hand.players[1].show?
  end

  test "комбинация игрока считается на каждой улице" do
    {hand, _events} = start([1000, 1000])

    # До флопа комбинации ещё нет: пяти карт не набирается.
    assert Hand.combination(hand, 1) == nil

    {hand, _} = act!(hand, 1, :call)
    {hand, _} = act!(hand, 2, :check)

    assert hand.street == :flop
    assert %{category: category} = Hand.combination(hand, 1)
    assert is_atom(category)
  end

  test "анте за стол вносит большой блайнд и оно не идёт в счёт его ставки" do
    {hand, events} = start([1000, 1000, 1000], ante: 10)

    assert Enum.any?(events, &match?({:posted, %{kind: "ante", amount: 10}}, &1))
    assert hand.pot == 25
    assert hand.players[3].committed == 10
    assert hand.players[3].stack == 980
  end
end
