defmodule BlockPoker.Engine.SeatingTest do
  @moduledoc """
  Балансировка рассадки. Чистый расчёт: столы на входе, пересадки
  на выходе.

  Property здесь сторожит само правило — после применения плана разница
  между любыми двумя столами не больше одного, — и два свойства, без
  которых правило выполнялось бы нечестно: игрока не двигают дважды и
  занятые раздачей столы не трогают.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BlockPoker.Engine.Seating

  defp table(id, players, opts \\ []) do
    size = Keyword.get(opts, :size, 6)
    seats = Map.new(1..size, fn number -> {number, Enum.at(players, number - 1)} end)

    %{
      id: id,
      seats: seats,
      big_blind_seat: Keyword.get(opts, :big_blind_seat),
      busy?: Keyword.get(opts, :busy?, false)
    }
  end

  # Применяет план к столам, чтобы проверять результат, а не намерение.
  defp apply_plan(tables, plan) do
    tables
    |> Enum.reject(&(&1.id in plan.close))
    |> Enum.map(fn t ->
      seats =
        Enum.reduce(plan.moves, t.seats, fn move, seats ->
          cond do
            move.from == t.id -> vacate(seats, move.player)
            move.to == t.id -> Map.put(seats, move.seat, move.player)
            true -> seats
          end
        end)

      %{t | seats: seats}
    end)
  end

  defp vacate(seats, player) do
    Map.new(seats, fn {number, occupant} ->
      {number, if(occupant == player, do: nil, else: occupant)}
    end)
  end

  describe "сколько столов нужно" do
    test "делится нацело" do
      assert Seating.tables_needed(18, 6) == 3
    end

    test "остаток требует ещё одного стола" do
      assert Seating.tables_needed(19, 6) == 4
    end

    test "пустой турнир столов не держит" do
      assert Seating.tables_needed(0, 6) == 0
    end
  end

  describe "схлопывание" do
    test "лишний стол убирается, его игроки расходятся" do
      tables = [
        table(:a, [:p1, :p2]),
        table(:b, [:p3, :p4]),
        table(:c, [:p5])
      ]

      plan = Seating.plan(tables, 6)

      # Пятеро помещаются за один стол.
      assert length(plan.close) == 2
      assert length(plan.moves) == 3
    end

    test "убирается стол с наименьшим числом игроков" do
      # 11 игроков требуют двух столов из трёх: лишним оказывается тот,
      # где людей меньше всего, — пересадок от этого меньше всего.
      tables = [
        table(:full, [:p1, :p2, :p3, :p4, :p5]),
        table(:half, [:p6, :p7, :p8, :p9, :p10]),
        table(:thin, [:p11])
      ]

      plan = Seating.plan(tables, 6)

      assert plan.close == [:thin]
    end

    test "схлопывание не выселяет больше, чем помещается" do
      tables = [table(:a, [:p1, :p2, :p3]), table(:b, [:p4, :p5, :p6])]

      plan = Seating.plan(tables, 6)

      assert plan.close == [:b]
      assert length(plan.moves) == 3
    end
  end

  describe "выравнивание" do
    test "перекос больше единицы устраняется" do
      tables = [
        table(:a, [:p1, :p2, :p3, :p4, :p5, :p6], size: 9),
        table(:b, [:p7, :p8], size: 9)
      ]

      plan = Seating.plan(tables, 9)
      balanced = apply_plan(tables, plan)

      counts = Enum.map(balanced, &Seating.occupancy/1)
      assert Enum.max(counts) - Enum.min(counts) <= 1
    end

    test "уже сбалансированные столы не трогаются" do
      # Десятеро за шестимаксом требуют обоих столов, и разница уже нулевая:
      # трогать нечего.
      tables = [
        table(:a, [:p1, :p2, :p3, :p4, :p5]),
        table(:b, [:p6, :p7, :p8, :p9, :p10])
      ]

      plan = Seating.plan(tables, 6)

      assert plan.moves == []
      assert plan.close == []
    end
  end

  describe "кого увозить" do
    test "первым уезжает тот, кто только что заплатил большой блайнд" do
      # Большой блайнд на месте 2: он и есть «самая поздняя» позиция —
      # платить снова ему через целый круг.
      t = table(:a, [:p1, :p2, :p3, :p4], big_blind_seat: 2)

      assert [{2, :p2} | _rest] = Seating.departure_order(t)
    end

    test "без большого блайнда порядок задаёт номер места" do
      t = table(:a, [:p1, :p2, :p3])

      assert Enum.map(Seating.departure_order(t), &elem(&1, 0)) == [1, 2, 3]
    end
  end

  describe "занятые столы" do
    test "стол с идущей раздачей не трогается" do
      tables = [
        table(:busy, [:p1, :p2, :p3, :p4, :p5, :p6], size: 9, busy?: true),
        table(:free, [:p7], size: 9)
      ]

      plan = Seating.plan(tables, 9)

      assert Enum.all?(plan.moves, &(&1.from != :busy and &1.to != :busy))
      refute :busy in plan.close
    end

    test "игроков не пересаживают на свободные места занятого стола" do
      # Троих глобально хватило бы на один стол, но два из них сидят
      # за свободными столами, а третий — за занятым, куда сейчас
      # никого не посадить. Снести оба свободных нельзя: игрокам
      # некуда идти.
      tables = [
        table(:busy, [:p1], busy?: true),
        table(:b, [:p2]),
        table(:c, [:p3])
      ]

      plan = Seating.plan(tables, 6)
      balanced = apply_plan(tables, plan)

      assert Enum.sum(Enum.map(balanced, &Seating.occupancy/1)) == 3
    end

    test "игроки занятого стола всё равно считаются при схлопывании" do
      # Шестеро за занятым столом плюс один — в один стол на шесть
      # они не влезают, и сносить свободный стол нельзя.
      tables = [
        table(:busy, [:p1, :p2, :p3, :p4, :p5, :p6], busy?: true),
        table(:free, [:p7])
      ]

      plan = Seating.plan(tables, 6)

      assert plan.close == []
    end
  end

  describe "посадка" do
    test "эквивалентная позиция не меняет дистанцию до блайнда" do
      from = table(:a, [:p1, :p2, :p3, :p4, :p5, :p6], big_blind_seat: 1)
      to = table(:b, [:q1, nil, nil, nil, nil, nil], big_blind_seat: 3)

      plan = Seating.plan([from, to], 6)
      move = hd(plan.moves)

      refute move.wait_for_bb?
    end

    test "если эквивалентной позиции нет, игрок ждёт большого блайнда" do
      # Стол :a схлопывается, а у :b свободно единственное место — и оно
      # не совпадает по дистанции до блайнда с покинутым.
      from = table(:a, [:p1], big_blind_seat: 1)
      to = table(:b, [:q1, :q2, :q3, :q4, :q5, nil], big_blind_seat: 1)

      plan = Seating.plan([from, to], 6)

      assert [%{wait_for_bb?: true}] = plan.moves
    end
  end

  describe "инварианты" do
    property "после балансировки разница между столами не больше одного" do
      check all(
              counts <- list_of(integer(0..6), min_length: 1, max_length: 6),
              max_runs: 200
            ) do
        tables = build_tables(counts, 6)
        plan = Seating.plan(tables, 6)
        balanced = apply_plan(tables, plan)

        occupancies = balanced |> Enum.map(&Seating.occupancy/1) |> Enum.reject(&(&1 == 0))

        if occupancies != [] do
          assert Enum.max(occupancies) - Enum.min(occupancies) <= 1
        end
      end
    end

    property "ни один игрок не пересажен дважды за одну балансировку" do
      check all(counts <- list_of(integer(0..6), min_length: 1, max_length: 6), max_runs: 200) do
        plan = counts |> build_tables(6) |> Seating.plan(6)
        players = Enum.map(plan.moves, & &1.player)

        assert players == Enum.uniq(players)
      end
    end

    property "ни один игрок не теряется и не удваивается" do
      check all(counts <- list_of(integer(0..6), min_length: 1, max_length: 6), max_runs: 200) do
        tables = build_tables(counts, 6)
        before = occupants(tables)

        balanced = tables |> Seating.plan(6) |> then(&apply_plan(tables, &1))

        assert Enum.sort(occupants(balanced)) == Enum.sort(before)
      end
    end

    # Занятые столы — тот случай, где схлопывание однажды увозило игрока
    # в никуда: глобально места хватало, а физически сесть было некуда,
    # потому что свободные места занятого стола недоступны посреди раздачи.
    property "игрок не теряется и тогда, когда часть столов в раздаче" do
      check all(
              counts <- list_of(integer(0..6), min_length: 1, max_length: 6),
              busy <- list_of(boolean(), min_length: 1, max_length: 6),
              max_runs: 300
            ) do
        tables = build_tables(counts, 6, busy)
        before = occupants(tables)

        balanced = tables |> Seating.plan(6) |> then(&apply_plan(tables, &1))

        assert Enum.sort(occupants(balanced)) == Enum.sort(before)
      end
    end

    property "стол в раздаче не закрывают и не трогают его состав" do
      check all(
              counts <- list_of(integer(0..6), min_length: 1, max_length: 6),
              busy <- list_of(boolean(), min_length: 1, max_length: 6),
              max_runs: 300
            ) do
        tables = build_tables(counts, 6, busy)
        busy_ids = tables |> Enum.filter(& &1.busy?) |> MapSet.new(& &1.id)

        plan = Seating.plan(tables, 6)

        assert Enum.all?(plan.close, &(&1 not in busy_ids))
        assert Enum.all?(plan.moves, &(&1.from not in busy_ids and &1.to not in busy_ids))
      end
    end

    property "число столов после плана не меньше необходимого" do
      check all(counts <- list_of(integer(0..6), min_length: 1, max_length: 6), max_runs: 200) do
        tables = build_tables(counts, 6)
        total = Enum.sum(Enum.map(tables, &Seating.occupancy/1))

        plan = Seating.plan(tables, 6)
        left = length(tables) - length(plan.close)

        assert left >= Seating.tables_needed(total, 6)
      end
    end
  end

  defp build_tables(counts, size, busy \\ []) do
    {tables, _next} =
      counts
      |> Enum.with_index()
      |> Enum.map_reduce(1, fn {count, index}, next ->
        players = Enum.map(next..(next + count - 1)//1, &{:p, &1})
        busy? = Enum.at(busy, index, false)

        {table({:t, index}, players, size: size, busy?: busy?), next + count}
      end)

    tables
  end

  defp occupants(tables) do
    Enum.flat_map(tables, fn t ->
      for {_number, player} <- t.seats, player != nil, do: player
    end)
  end
end
