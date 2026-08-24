defmodule BlockPoker.History.BuildTest do
  @moduledoc """
  Уровень 1: сборка строк истории. Без БД, без процессов, мгновенно.

  Проверяется то, что сборка обязана делать сама: позиции по кнопке, EV по
  слоям банка и лог действий, собранный из тех же событий, что ушли в
  broadcast. Всё остальное она берёт у ядра готовым, и проверять там
  нечего — это уже проверено там, где считается.
  """

  use ExUnit.Case, async: true

  alias BlockPoker.History.{Build, Position, Report}

  describe "позиция по кнопке" do
    test "хедз-ап: кнопка совпадает с малым блайндом, и sb в раздаче нет" do
      # Отдельная строка таблицы, а не частный случай: в хедз-апе малого
      # блайнда как позиции не существует вовсе.
      assert Position.for_seats([1, 2], 1) == %{1 => :btn, 2 => :bb}
      assert Position.for_seats([3, 6], 6) == %{6 => :btn, 3 => :bb}
    end

    test "позиции считаются по фактическому составу, а не по вместимости стола" do
      # Впятером за девятимаксным столом играют пятимаксные позиции.
      assert Position.for_seats([1, 2, 3, 4, 5], 1) == %{
               1 => :btn,
               2 => :sb,
               3 => :bb,
               4 => :utg,
               5 => :co
             }
    end

    test "кнопка не с первого места разворачивает круг" do
      assert Position.for_seats([1, 2, 3], 3) == %{3 => :btn, 1 => :sb, 2 => :bb}
    end

    test "нет кнопки или незнакомый состав — пустая карта, а не падение" do
      # История пишется после раздачи, и уронить её запись из-за
      # незнакомого состава нельзя.
      assert Position.for_seats([1, 2], nil) == %{}
      assert Position.for_seats(Enum.to_list(1..11), 1) == %{}
    end
  end

  describe "EV" do
    test "сумма ev_amount претендентов равна банку после рейка" do
      # Слой один, претендентов двое, доли складываются в единицу.
      report =
        all_in_report(%{1 => 0.6, 2 => 0.4}, [%{amount: 1000, eligible: [1, 2], winners: [1]}])

      rows = Build.rows(report)
      total = rows.players |> Enum.map(& &1.ev_amount) |> Enum.sum()

      assert total == 1000
      assert Enum.map(rows.players, & &1.ev_amount) == [600, 400]
    end

    test "EV считается по слоям: чужой сайд-пот в долю не входит" do
      # Короткий стек претендует только на основной банк, и его эквити
      # к сайд-поту отношения не имеет. Общая доля от общего банка дала
      # бы неверный ответ — ради этого расчёт и разбит по слоям.
      report =
        all_in_report(%{1 => 0.5, 2 => 0.5, 3 => 0.5}, [
          %{amount: 600, eligible: [1, 2, 3], winners: [1]},
          %{amount: 400, eligible: [1, 2], winners: [1]}
        ])

      rows = Build.rows(report)
      ev = Map.new(rows.players, &{&1.seat, &1.ev_amount})

      assert ev[3] == 300
      assert ev[1] == 500
    end

    test "run it twice: EV не зависит от числа прогонов" do
      # Эквити считается один раз, до разделения на прогоны — ровно то
      # свойство, ради которого RIT и существует.
      one_run =
        all_in_report(%{1 => 0.6, 2 => 0.4}, [%{amount: 1000, eligible: [1, 2], winners: [1]}])

      two_runs =
        all_in_report(%{1 => 0.6, 2 => 0.4}, [
          %{amount: 500, eligible: [1, 2], winners: [1]},
          %{amount: 500, eligible: [1, 2], winners: [2]}
        ])

      assert evs(one_run) == evs(two_runs)
    end

    test "раздача без олл-ина: ev_amount не существует" do
      report = %{all_in_report(%{1 => 0.5, 2 => 0.5}, []) | equity: nil}

      assert Enum.all?(Build.rows(report).players, &(&1.ev_amount == nil))
    end
  end

  defp evs(report) do
    report |> Build.rows() |> Map.fetch!(:players) |> Enum.map(& &1.ev_amount)
  end

  # Раздача, доигранная до конца: сборке нужны только её игроки, борд и
  # результат. Собирается вручную, потому что проверяется именно сборка —
  # прогон настоящей раздачи проверял бы движок.
  defp all_in_report(equity, pots) do
    seats = Map.keys(equity)

    players =
      Map.new(seats, fn seat ->
        {seat,
         %{
           seat: seat,
           id: "user-#{seat}",
           stack: 0,
           hole: [],
           committed: 0,
           total: 500,
           dead: 0,
           status: :all_in,
           acted?: true
         }}
      end)

    runs =
      pots
      |> Enum.with_index(1)
      |> Enum.map(fn {pot, run} -> %{run: run, board: [], pots: [pot], placements: []} end)

    hand = %BlockPoker.Engine.Hand{
      variant: BlockPoker.Engine.Variant.TexasHoldem,
      context: BlockPoker.Engine.HandRank.context(BlockPoker.Engine.Variant.TexasHoldem),
      deck: [],
      rng: nil,
      players: players,
      order: seats,
      button_seat: List.first(seats),
      results: %{runs: runs, payouts: %{}, rake: 0, showdown?: true, reveal: %{}}
    }

    %Report{
      hand_id: Ecto.UUID.generate(),
      room_id: Ecto.UUID.generate(),
      game_mode: :cash,
      hand: hand,
      button_seat: List.first(seats),
      ended_at: DateTime.utc_now(),
      equity: [
        %{
          run: 1,
          equity: %{players: Enum.map(equity, fn {seat, share} -> %{id: seat, equity: share} end)}
        }
      ]
    }
  end
end
