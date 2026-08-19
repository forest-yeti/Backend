defmodule BlockPoker.Engine.RunItTwiceTest do
  @moduledoc """
  Два прогона борда при олл-ине.

  Проверяется три сорта вещей, и они не смешиваются:

    * **согласие** — кого спрашивают, кто как ответил, что значит молчание;
    * **деньги** — банк делится пополам, рейк берётся один раз, ни одна
      фишка не появляется и не пропадает;
    * **карты** — борды не пересекаются, а ауты второго прогона считаются
      с учётом того, что уже легло на первый.
  """

  use ExUnit.Case, async: true

  alias BlockPoker.Engine.{Card, Hand, HandSetup, Rng, RunItTwice}
  alias BlockPoker.Engine.Variant.TexasHoldem

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
      run_it_twice_allowed: Keyword.get(opts, :allowed, true)
    }
  end

  defp start(stacks, opts \\ []) do
    setup = setup_hand(stacks, opts)
    rake = Keyword.get(opts, :rake)

    {hand, _events} =
      Hand.start(setup, Rng.seeded(Keyword.get(opts, :seed, <<7::256>>)), rake: rake)

    hand
  end

  defp act!(hand, seat, action) do
    {:ok, hand, events} = Hand.act(hand, seat, action, nil)
    {hand, events}
  end

  # Олл-ин двоих на префлопе: самая короткая дорога до предложения.
  defp all_in_heads_up(opts \\ []) do
    hand = start(Keyword.get(opts, :stacks, [200, 200]), opts)
    {hand, _} = act!(hand, 1, :all_in)
    act!(hand, 2, :call)
  end

  defp run_out(hand) do
    Enum.reduce_while(1..30, hand, fn _step, acc ->
      if Hand.finished?(acc) do
        {:halt, acc}
      else
        {:ok, acc, _events} = Hand.deal_next(acc)
        {:cont, acc}
      end
    end)
  end

  defp accept_both(hand), do: accept_both_of(hand, [1, 2])

  defp accept_both_of(hand, [first, second]) do
    {:ok, hand, _} = Hand.answer_run_it_twice(hand, first, true)
    {:ok, hand, events} = Hand.answer_run_it_twice(hand, second, true)
    {hand, events}
  end

  defp pot_size(run), do: Enum.sum(Enum.map(run.pots, & &1.amount))

  describe "когда спрашивают" do
    test "двоих в олл-ине на неполном борде — спрашивают" do
      {hand, events} = all_in_heads_up()

      assert Hand.offering_run_it_twice?(hand)
      assert hand.rit.seats == [1, 2]

      # Карты вскрываются раньше вопроса: игрок решает, видя расклад.
      assert [{:all_in_showdown, _}, {:run_it_twice_offer, offer}] =
               Enum.filter(events, &(elem(&1, 0) in [:all_in_showdown, :run_it_twice_offer]))

      assert offer.seats == [1, 2]

      # Пока идёт вопрос, борд не сдаётся ни на карту.
      assert hand.board == []
      assert {:error, :not_running_out} = Hand.deal_next(hand)
    end

    test "стол без разрешения не спрашивает вовсе" do
      {hand, events} = all_in_heads_up(allowed: false)

      refute Hand.offering_run_it_twice?(hand)
      assert hand.runout?
      refute Enum.any?(events, &match?({:run_it_twice_offer, _}, &1))
    end

    test "троих не спрашивают: прогоны только heads-up" do
      hand = start([200, 200, 200])
      {hand, _} = act!(hand, 1, :all_in)
      {hand, _} = act!(hand, 2, :all_in)
      {hand, _} = act!(hand, 3, :all_in)

      refute Hand.offering_run_it_twice?(hand)
      assert hand.runout?
    end

    test "на полном борде разыгрывать нечего" do
      hand = start([200, 200])
      {hand, _} = act!(hand, 1, :call)
      {hand, _} = act!(hand, 2, :check)

      # Три улицы чеков — борд полон, и только теперь олл-ин.
      hand =
        Enum.reduce(1..3, hand, fn _street, acc ->
          {acc, _} = act!(acc, acc.to_act, :check)
          {acc, _} = act!(acc, acc.to_act, :check)
          acc
        end)

      assert hand.street == :river or Hand.finished?(hand)
      refute Hand.offering_run_it_twice?(hand)
    end
  end

  describe "согласие" do
    test "согласились оба — играем дважды" do
      {hand, _} = all_in_heads_up()
      {hand, events} = accept_both(hand)

      assert [{:run_it_twice_decided, decided}] = events
      assert decided.accepted
      assert hand.board_2 == hand.board
      assert hand.runout?
      refute Hand.offering_run_it_twice?(hand)
    end

    test "отказ одного закрывает вопрос немедленно, второго не ждём" do
      {hand, _} = all_in_heads_up()
      {:ok, hand, events} = Hand.answer_run_it_twice(hand, 1, false)

      assert [{:run_it_twice_decided, %{accepted: false}}] = events
      assert hand.board_2 == nil
      assert hand.runout?

      # Вопрос закрыт — второй уже не отвечает.
      assert {:error, :run_it_twice_not_offered} = Hand.answer_run_it_twice(hand, 2, true)
    end

    test "молчание — отказ" do
      {hand, _} = all_in_heads_up()
      {:ok, hand, _} = Hand.answer_run_it_twice(hand, 1, true)

      # Второй не ответил, окно закрылось снаружи по таймеру.
      {:ok, hand, events} = Hand.close_run_it_twice(hand)

      assert [{:run_it_twice_decided, %{accepted: false}}] = events
      assert hand.board_2 == nil
      assert hand.runout?
    end

    test "ответ не претендента и повторный ответ отклоняются" do
      # Кнопка на месте 1, значит блайнды — на 2 и 3, а ход начинает 1.
      hand = start([200, 200, 200])
      {hand, _} = act!(hand, 1, :fold)
      {hand, _} = act!(hand, 2, :all_in)
      {hand, _} = act!(hand, 3, :call)

      assert Hand.offering_run_it_twice?(hand)
      assert {:error, :not_a_contender} = Hand.answer_run_it_twice(hand, 1, true)

      {:ok, hand, _} = Hand.answer_run_it_twice(hand, 2, true)
      assert {:error, :already_answered} = Hand.answer_run_it_twice(hand, 2, false)
    end

    test "вопроса не было — отвечать нечего" do
      {hand, _} = all_in_heads_up(allowed: false)
      assert {:error, :run_it_twice_not_offered} = Hand.answer_run_it_twice(hand, 1, true)
      assert {:error, :run_it_twice_not_offered} = Hand.close_run_it_twice(hand)
    end
  end

  describe "борды" do
    test "второй прогон не пересекается с первым и с карманными картами" do
      {hand, _} = all_in_heads_up()
      {hand, _} = accept_both(hand)
      hand = run_out(hand)

      assert length(hand.board) == 5
      assert length(hand.board_2) == 5

      holes = hand.players |> Map.values() |> Enum.flat_map(& &1.hole)
      all = hand.board ++ hand.board_2 ++ holes

      assert length(Enum.uniq(all)) == length(all)
    end

    test "борды расходятся с улицы олл-ина, общий префикс остаётся общим" do
      hand = start([200, 200])
      {hand, _} = act!(hand, 1, :call)
      {hand, _} = act!(hand, 2, :check)
      # Флоп сдан обоим ещё до вопроса — он общий.
      {hand, _} = act!(hand, hand.to_act, :all_in)
      {hand, _} = act!(hand, hand.to_act, :call)

      assert Hand.offering_run_it_twice?(hand)
      {hand, _} = accept_both(hand)
      flop = hand.board

      hand = run_out(hand)

      assert Enum.take(hand.board, 3) == flop
      assert Enum.take(hand.board_2, 3) == flop
      assert Enum.drop(hand.board, 3) != Enum.drop(hand.board_2, 3)
    end

    test "отказ даёт ровно ту же раздачу, что и стол без run it twice" do
      {declined, _} = all_in_heads_up(seed: <<42::256>>)
      {:ok, declined, _} = Hand.answer_run_it_twice(declined, 1, false)
      declined = run_out(declined)

      {plain, _} = all_in_heads_up(seed: <<42::256>>, allowed: false)
      plain = run_out(plain)

      assert declined.board == plain.board
      assert declined.results.payouts == plain.results.payouts
      assert declined.results.rake == plain.results.rake
      assert length(declined.results.runs) == 1
    end
  end

  describe "деньги" do
    test "банк делится пополам, фишки не появляются и не исчезают" do
      {hand, _} = all_in_heads_up()
      {hand, _} = accept_both(hand)
      hand = run_out(hand)

      assert Hand.total_chips(hand) == 400
      assert [%{run: 1}, %{run: 2}] = hand.results.runs

      # Каждый прогон разыграл ровно половину.
      for run <- hand.results.runs, do: assert(pot_size(run) == 200)
    end

    test "нечётная фишка достаётся победителю первого прогона" do
      # Нечётный банк собирается мёртвыми деньгами: малый блайнд сбросил,
      # его пятёрка осталась в банке. 200 + 200 + 5 = 405.
      hand = start([200, 200, 200])
      {hand, _} = act!(hand, 1, :all_in)
      {hand, _} = act!(hand, 2, :fold)
      {hand, _} = act!(hand, 3, :call)

      {hand, _} = accept_both_of(hand, [1, 3])
      hand = run_out(hand)

      [first, second] = Enum.map(hand.results.runs, &pot_size/1)

      assert first + second == 405
      assert first - second == 1
      assert Hand.total_chips(hand) == 600
    end

    test "рейк берётся один раз, а не по разу на прогон" do
      rake = fn pot, _players, _opts -> div(pot, 10) end

      {twice, _} = all_in_heads_up(rake: rake)
      {twice, _} = accept_both(twice)
      twice = run_out(twice)

      {once, _} = all_in_heads_up(rake: rake, allowed: false)
      once = run_out(once)

      assert twice.results.rake == once.results.rake
      assert Hand.total_chips(twice) == 400 - twice.results.rake
    end

    test "выигравший оба прогона забирает банк целиком, один — половину" do
      {hand, _} = all_in_heads_up()
      {hand, _} = accept_both(hand)
      hand = run_out(hand)

      winners =
        hand.results.runs
        |> Enum.flat_map(fn run -> Enum.flat_map(run.pots, & &1.winners) end)
        |> Enum.frequencies()

      total = Enum.sum(Map.values(hand.results.payouts))
      assert total == 400

      # Кто взял оба прогона, забрал всё; кто один — примерно половину.
      for {seat, taken} <- winners, taken == 2 do
        assert hand.results.payouts[seat] == 400
      end
    end
  end

  describe "ауты и эквити" do
    test "аут, ушедший на первый борд, во втором прогоне уже не аут" do
      # Расклад собран руками ровно под сценарий, ради которого этот счёт
      # существует.
      #
      #   борд:  A♥ K♦ 7♣      p1: A♠A♣ (сет тузов)   p2: Q♥J♥
      #
      # У второго ровно четыре аута — четыре десятки, дающие стрит. На тёрне
      # первого прогона приходит T♥: игрок переехал, но на ривере приходит A♦
      # и он всё равно проигрывает фул-хаусу. Во втором прогоне десяток
      # остаётся три: червовая лежит на первом борде и выйти не может.
      {hand, offer_events} = rigged_hand()

      assert [{:all_in_showdown, %{equity: [%{run: 1, equity: on_flop}]}}] =
               Enum.filter(offer_events, &match?({:all_in_showdown, _}, &1))

      assert length(outs_of(on_flop, 2)) == 4

      {hand, _} = accept_both(hand)
      {:ok, hand, events} = Hand.deal_next(hand)

      assert [{:equity_update, [%{run: 1, equity: first}, %{run: 2, equity: second}]}] =
               Enum.filter(events, &match?({:equity_update, _}, &1))

      # Первый прогон: аут пришёл, игрок ведёт — аутов у него больше нет.
      assert List.last(hand.board) == card("Th")
      assert outs_of(first, 2) == []

      # Второй прогон: аутов осталось три, и червовой десятки среди них нет.
      second_outs = outs_of(second, 2)
      assert length(second_outs) == 3
      refute card("Th") in second_outs

      # Доигрываем: на ривере первого прогона тузы собирают фул-хаус.
      hand = run_out(hand)
      assert card("Ad") in hand.board
      assert hand.results.payouts[1] > 0
    end

    test "в момент вопроса борды совпадают и шансы одинаковы" do
      {hand, events} = all_in_heads_up()
      {hand, _} = accept_both(hand)

      assert [{:all_in_showdown, payload}] =
               Enum.filter(events, &match?({:all_in_showdown, _}, &1))

      # Вопрос задан до расхождения бордов: прогон в этот момент ещё один.
      assert [%{run: 1, equity: _}] = payload.equity
      assert hand.board_2 == hand.board
    end
  end

  describe "rabbit hunting" do
    test "после двух прогонов показывать нечего" do
      {hand, _} = all_in_heads_up()
      {hand, _} = accept_both(hand)
      hand = run_out(hand)

      assert {:error, :showdown} = BlockPoker.Engine.Rabbit.runout(hand)
    end
  end

  describe "чистое согласие" do
    test "оба да — принято" do
      rit = RunItTwice.offer([3, 5])
      assert RunItTwice.offered?(rit)

      {:ok, rit} = RunItTwice.answer(rit, 3, true)
      assert RunItTwice.offered?(rit)

      {:ok, rit} = RunItTwice.answer(rit, 5, true)
      refute RunItTwice.offered?(rit)
      assert RunItTwice.accepted?(rit)
    end

    test "закрытие без ответов — отказ" do
      rit = [3, 5] |> RunItTwice.offer() |> RunItTwice.close()

      refute RunItTwice.accepted?(rit)
      assert rit.status == :declined
    end
  end

  # Раздача с заранее заданными картами: подменяется **результат** тасовки,
  # а не её источник — RNG остаётся нетронутым (§9 CLAUDE.md).
  #
  # Олл-ин делается на флопе, чтобы флоп был общим для обоих прогонов:
  # расходятся они с той улицы, на которой кончилась торговля.
  defp rigged_hand do
    hand = start([200, 200])

    hand = %{
      hand
      | players: %{
          1 => %{hand.players[1] | hole: cards(~w(As Ac))},
          2 => %{hand.players[2] | hole: cards(~w(Qh Jh))}
        },
        # Флоп, затем тёрн и ривер первого прогона вперемешку со вторым:
        # улицы откусываются парами, первый борд — первым.
        deck: cards(~w(Ah Kd 7c Th 2c Ad 3d 8s 9c 5d 6s))
    }

    {hand, _} = act!(hand, 1, :call)
    {hand, _} = act!(hand, 2, :check)

    {hand, _} = act!(hand, hand.to_act, :all_in)
    act!(hand, hand.to_act, :call)
  end

  defp cards(list), do: Enum.map(list, &card/1)

  defp card(<<rank::binary-1, suit::binary-1>>) do
    ranks = %{
      "2" => 0,
      "3" => 1,
      "4" => 2,
      "5" => 3,
      "6" => 4,
      "7" => 5,
      "8" => 6,
      "9" => 7,
      "T" => 8,
      "J" => 9,
      "Q" => 10,
      "K" => 11,
      "A" => 12
    }

    suits = %{"c" => 0, "d" => 1, "h" => 2, "s" => 3}
    Map.fetch!(ranks, rank) * 4 + Map.fetch!(suits, suit)
  end

  defp outs_of(equity, seat) do
    equity
    |> Enum.find(&(&1.seat == seat))
    |> Map.fetch!(:outs)
    |> Enum.flat_map(& &1.cards)
    |> Enum.map(fn map ->
      {:ok, card} = Card.from_map(map)
      card
    end)
  end
end
