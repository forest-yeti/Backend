defmodule BlockPoker.Engine.StatsTest do
  @moduledoc """
  Показатели игрока: счётчики раздачи и производные проценты.

  Раздача играется настоящим `Engine.Hand` и её же событиями — считать
  статистику по выдуманному списку событий значило бы проверять фикстуру,
  а не то, что реально уходит со стола.
  """

  use ExUnit.Case, async: true

  alias BlockPoker.Engine.{Hand, HandSetup, HandStats, Rng, Stats}
  alias BlockPoker.Engine.Variant.TexasHoldem

  # Три игрока, блайнды 5/10: место 1 — кнопка, 2 — малый блайнд, 3 — большой.
  defp start(stacks \\ [1000, 1000, 1000]) do
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

    {hand, events} = Hand.start(setup, Rng.seeded(<<7::256>>))
    {hand, track(HandStats.new(hand), events)}
  end

  defp track(stats, events), do: Enum.reduce(events, stats, &HandStats.track(&2, &1))

  defp act(hand, stats, seat, action) do
    {:ok, hand, events} = Hand.act(hand, seat, action, nil)
    {hand, track(stats, events)}
  end

  defp run_out(hand, stats) do
    Enum.reduce_while(1..10, {hand, stats}, fn _step, {hand, stats} ->
      if Hand.finished?(hand) do
        {:halt, {hand, stats}}
      else
        {:ok, hand, events} = Hand.deal_next(hand)
        {:cont, {hand, track(stats, events)}}
      end
    end)
  end

  defp finish(hand, stats), do: HandStats.finish(stats, hand)

  describe "VPIP и PFR" do
    test "блайнд сам по себе добровольным вложением не считается" do
      {hand, stats} = start()
      {hand, stats} = act(hand, stats, 1, :fold)
      {hand, stats} = act(hand, stats, 2, :fold)

      deltas = finish(hand, stats)

      # Большой блайнд забрал банк, не сделав ни одного действия.
      assert %Stats{hands: 1, vpip: 0, pfr: 0} = deltas[3]
      assert %Stats{hands: 1, vpip: 0, pfr: 0} = deltas[1]
    end

    test "колл на префлопе — VPIP без PFR, рейз — оба" do
      {hand, stats} = start()
      {hand, stats} = act(hand, stats, 1, :call)
      {hand, stats} = act(hand, stats, 2, {:raise, 40})
      {hand, stats} = act(hand, stats, 3, :fold)
      {hand, stats} = act(hand, stats, 1, :fold)

      deltas = finish(hand, stats)

      assert %Stats{vpip: 1, pfr: 0} = deltas[1]
      assert %Stats{vpip: 1, pfr: 1} = deltas[2]
      assert %Stats{vpip: 0, pfr: 0} = deltas[3]
    end

    test "чек большого блайнда VPIP не даёт" do
      {hand, stats} = start()
      {hand, stats} = act(hand, stats, 1, :call)
      {hand, stats} = act(hand, stats, 2, :call)
      {hand, stats} = act(hand, stats, 3, :check)

      assert %Stats{vpip: 0, pfr: 0} = finish(hand, stats)[3]
    end
  end

  describe "3-Bet" do
    test "возможность засчитывается всем, кто ходил после рейза" do
      {hand, stats} = start()
      {hand, stats} = act(hand, stats, 1, {:raise, 30})
      {hand, stats} = act(hand, stats, 2, {:raise, 90})
      {hand, stats} = act(hand, stats, 3, :fold)
      {hand, stats} = act(hand, stats, 1, :fold)

      deltas = finish(hand, stats)

      # Открывший рейз возможности ререйза не имел — до него рейзов не было.
      assert %Stats{three_bet_chances: 1, three_bets: 0} = deltas[1]
      assert %Stats{three_bet_chances: 1, three_bets: 1} = deltas[2]

      # Пас в ответ на рейз — тоже возможность, которой не воспользовались.
      assert %Stats{three_bet_chances: 1, three_bets: 0} = deltas[3]
    end

    test "без рейза на префлопе возможности ререйза не возникает" do
      {hand, stats} = start()
      {hand, stats} = act(hand, stats, 1, :call)
      {hand, stats} = act(hand, stats, 2, :call)
      {hand, stats} = act(hand, stats, 3, :check)

      deltas = finish(hand, stats)

      assert Enum.all?(Map.values(deltas), &(&1.three_bet_chances == 0))
    end
  end

  describe "AF" do
    test "считается только постфлоп: бет и рейз против колла" do
      {hand, stats} = start()
      {hand, stats} = act(hand, stats, 1, :call)
      {hand, stats} = act(hand, stats, 2, :call)
      {hand, stats} = act(hand, stats, 3, :check)

      # Флоп: 2 ставит, 3 коллирует, 1 пасует.
      {hand, stats} = act(hand, stats, 2, {:bet, 30})
      {hand, stats} = act(hand, stats, 3, :call)
      {hand, stats} = act(hand, stats, 1, :fold)

      deltas = finish(hand, stats)

      assert %Stats{aggressive: 1, calls: 0} = deltas[2]
      assert %Stats{aggressive: 0, calls: 1} = deltas[3]
      # Префлоп-колл в AF не входит.
      assert %Stats{aggressive: 0, calls: 0} = deltas[1]
    end

    test "олл-ин, не перебивший ставку, — это колл, а не агрессия" do
      # У третьего игрока 40 фишек: 10 уходят в большой блайнд, и его олл-ин
      # на постфлопе меньше ставки соперника.
      {hand, stats} = start([1000, 1000, 40])
      {hand, stats} = act(hand, stats, 1, :call)
      {hand, stats} = act(hand, stats, 2, :call)
      {hand, stats} = act(hand, stats, 3, :check)

      {hand, stats} = act(hand, stats, 2, {:bet, 100})
      {hand, stats} = act(hand, stats, 3, :all_in)
      {hand, stats} = act(hand, stats, 1, :fold)
      {hand, stats} = run_out(hand, stats)

      assert %Stats{aggressive: 0, calls: 1} = finish(hand, stats)[3]
    end
  end

  describe "WTSD" do
    test "знаменатель — увиденные флопы, числитель — дошедшие до вскрытия" do
      {hand, stats} = start()
      {hand, stats} = act(hand, stats, 1, :fold)
      {hand, stats} = act(hand, stats, 2, :call)
      {hand, stats} = act(hand, stats, 3, :check)

      {hand, stats} = act(hand, stats, 2, :check)
      {hand, stats} = act(hand, stats, 3, :check)
      {hand, stats} = act(hand, stats, 2, :check)
      {hand, stats} = act(hand, stats, 3, :check)
      {hand, stats} = act(hand, stats, 2, :check)
      {hand, stats} = act(hand, stats, 3, :check)

      deltas = finish(hand, stats)

      assert %Stats{saw_flop: 1, showdowns: 1} = deltas[2]
      assert %Stats{saw_flop: 1, showdowns: 1} = deltas[3]

      # Пас на префлопе: флопа не видел, во вскрытии не участвовал.
      assert %Stats{saw_flop: 0, showdowns: 0} = deltas[1]
    end

    test "выигрыш без вскрытия в числитель не идёт" do
      {hand, stats} = start()
      {hand, stats} = act(hand, stats, 1, :fold)
      {hand, stats} = act(hand, stats, 2, :call)
      {hand, stats} = act(hand, stats, 3, :check)

      {hand, stats} = act(hand, stats, 2, {:bet, 50})
      {hand, stats} = act(hand, stats, 3, :fold)

      deltas = finish(hand, stats)

      assert %Stats{saw_flop: 1, showdowns: 0} = deltas[2]
      assert %Stats{saw_flop: 1, showdowns: 0} = deltas[3]
    end
  end

  describe "summary/1" do
    test "проценты считаются от своих знаменателей" do
      stats = %Stats{
        hands: 20,
        vpip: 5,
        pfr: 3,
        three_bet_chances: 4,
        three_bets: 1,
        saw_flop: 8,
        showdowns: 2,
        aggressive: 6,
        calls: 4
      }

      assert Stats.summary(stats) == %{
               hands: 20,
               vpip: 25,
               pfr: 15,
               three_bet: 25,
               wtsd: 25,
               af: 1.5,
               aggressive_actions: 6,
               calls: 4
             }
    end

    test "без выборки — nil, а не ноль процентов" do
      summary = Stats.summary(Stats.new())

      assert summary.hands == 0
      assert summary.vpip == nil
      assert summary.pfr == nil
      assert summary.three_bet == nil
      assert summary.wtsd == nil
      assert summary.af == nil
    end

    test "merge складывает счётчики, а не проценты" do
      tight = %Stats{hands: 10, vpip: 1}
      loose = %Stats{hands: 10, vpip: 9}

      merged = Stats.merge(tight, loose)

      assert merged.hands == 20

      # 10% и 90% на равных выборках дают 50%, а не среднее по каким-то другим
      # правилам — важно, что делим один раз, в конце.
      assert Stats.summary(merged).vpip == 50
    end
  end
end
