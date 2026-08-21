defmodule BlockPoker.Engine.RevealTest do
  @moduledoc """
  Правила вскрытия: кто открывается первым и кто вправе спрятать карты.

  Тесты строят раздачу и её итог руками — так проверяется именно решение
  о показе, а не то, какие карты выпали из колоды по seed.
  """

  use ExUnit.Case, async: true

  alias BlockPoker.Engine.{Hand, HandRank, Reveal}
  alias BlockPoker.Engine.Variant.TexasHoldem

  defp hand(opts) do
    statuses = Keyword.fetch!(opts, :statuses)

    players =
      Map.new(statuses, fn {seat, status} ->
        {seat,
         %{
           seat: seat,
           id: "p#{seat}",
           stack: 100,
           hole: [0, 1],
           committed: 0,
           total: 10,
           dead: 0,
           status: status,
           acted?: true
         }}
      end)

    %Hand{
      variant: TexasHoldem,
      context: HandRank.context(TexasHoldem),
      deck: [],
      rng: nil,
      players: players,
      order: Keyword.get(opts, :order, Enum.sort(Map.keys(statuses))),
      button_seat: Keyword.get(opts, :button, 1),
      aggressor: Keyword.get(opts, :aggressor),
      runout?: Keyword.get(opts, :runout?, false)
    }
  end

  # Итог раздачи в том виде, в каком его отдаёт `payout/1`: ранжировка по
  # каждому прогону. Меньше место — сильнее рука.
  defp results(places_by_run) do
    runs =
      places_by_run
      |> Enum.with_index(1)
      |> Enum.map(fn {places, index} ->
        %{
          run: index,
          board: [],
          pots: [],
          placements: Enum.map(places, fn {seat, place} -> %{player_id: seat, place: place} end)
        }
      end)

    %{runs: runs, payouts: %{}, rake: 0, showdown?: true}
  end

  describe "порядок вскрытия" do
    test "первым открывается последний агрессор" do
      hand = hand(statuses: %{1 => :active, 2 => :active, 3 => :active}, aggressor: 3)

      assert Reveal.order(hand) == [3, 1, 2]
    end

    test "улицу прочекали — первым открывается первый говоривший" do
      hand = hand(statuses: %{1 => :active, 2 => :active, 3 => :active}, order: [2, 3, 1])

      assert Reveal.order(hand) == [2, 3, 1]
    end

    test "сбросившие в порядок не входят" do
      hand = hand(statuses: %{1 => :folded, 2 => :active, 3 => :active}, aggressor: 2)

      assert Reveal.order(hand) == [2, 3]
    end
  end

  describe "мук" do
    test "проигравший не показывает карты, победитель показывает" do
      hand = hand(statuses: %{1 => :active, 2 => :active}, aggressor: 1)

      assert Reveal.decide(hand, results([%{1 => 1, 2 => 2}])) == %{1 => :show, 2 => :muck}
    end

    test "делящий банк обязан открыться" do
      hand = hand(statuses: %{1 => :active, 2 => :active}, aggressor: 1)

      assert Reveal.decide(hand, results([%{1 => 1, 2 => 1}])) == %{1 => :show, 2 => :show}
    end

    test "спрятанная рука не поднимает планку следующему" do
      # Открывается второй (он агрессор), третий слабее и мучует, первый
      # сильнее всех показанных — открывается и забирает банк.
      hand = hand(statuses: %{1 => :active, 2 => :active, 3 => :active}, aggressor: 2)

      assert Reveal.decide(hand, results([%{1 => 1, 2 => 2, 3 => 3}])) ==
               %{1 => :show, 2 => :show, 3 => :muck}
    end

    test "хватает победы на одном борде из двух" do
      hand = hand(statuses: %{1 => :active, 2 => :active}, aggressor: 1)
      runs = results([%{1 => 1, 2 => 2}, %{1 => 2, 2 => 1}])

      assert Reveal.decide(hand, runs) == %{1 => :show, 2 => :show}
    end
  end

  test "забравший банк открывается, даже если по месту выглядит проигравшим" do
    # Так бывает в hi-lo: слабейшая по high рука забирает low-половину.
    # Решение о показе обязано идти за деньгами, а не только за местом.
    hand = hand(statuses: %{1 => :active, 2 => :active}, aggressor: 1)

    results =
      results([%{1 => 1, 2 => 2}])
      |> put_in([:runs, Access.at(0), :pots], [%{amount: 100, winners: [2]}])

    assert Reveal.decide(hand, results) == %{1 => :show, 2 => :show}
  end

  describe "олл-ин" do
    test "при доводке борта открываются все: торговли больше нет" do
      hand =
        hand(statuses: %{1 => :all_in, 2 => :all_in, 3 => :folded}, aggressor: 1, runout?: true)

      assert Reveal.decide(hand, results([%{1 => 1, 2 => 2}])) ==
               %{1 => :show, 2 => :show, 3 => :muck}
    end

    test "ответивший олл-ину тоже открывается, хотя и проиграл" do
      # Один all-in, второй его заколлировал и остался единственным активным:
      # ставить больше некому, значит прятать нечего.
      hand = hand(statuses: %{1 => :all_in, 2 => :active}, aggressor: 1)

      assert Reveal.decide(hand, results([%{1 => 1, 2 => 2}])) == %{1 => :show, 2 => :show}
    end
  end

  test "раздача без вскрытия не открывает никого" do
    hand = hand(statuses: %{1 => :active, 2 => :folded})
    results = %{runs: [], payouts: %{}, rake: 0, showdown?: false}

    assert Reveal.decide(hand, results) == %{1 => :muck, 2 => :muck}
  end
end
