defmodule BlockPoker.Tournaments.GridTest do
  @moduledoc """
  Стандартная сетка турниров — то, ради чего она живёт в коде.

  Тест сторожит договор: сетка выплат исполнима при любой явке, доли
  складываются ровно, структура уровней доигрываема. Правка, которая это
  ломает, обязана падать здесь, а не обнаруживаться в пятницу вечером на
  турнире с гарантией.

  БД не нужна: сетка — чистые данные.
  """

  use ExUnit.Case, async: true

  alias BlockPoker.Engine.TournamentPayout
  alias BlockPoker.Tournaments.{BlindLevel, Grid}

  describe "структура уровней" do
    test "уровни идут подряд и заканчиваются закрытой регистрацией" do
      for speed <- [:regular, :turbo, :hyper] do
        levels = Enum.map(Grid.blind_levels(speed), &struct(BlindLevel, &1))

        assert BlindLevel.validate_set(levels, 500) == :ok,
               "структура #{speed} не проходит проверку набора"
      end
    end

    test "скорость меняет только длительность, но не номиналы" do
      regular = Grid.blind_levels(:regular)
      turbo = Grid.blind_levels(:turbo)

      assert Enum.map(regular, & &1.big_blind) == Enum.map(turbo, & &1.big_blind)
      assert hd(regular).duration_seconds == 600
      assert hd(turbo).duration_seconds == 300
    end

    test "каждый уровень несёт чем платить" do
      for level <- Grid.blind_levels(:regular) do
        assert level.big_blind > 0 or level.ante > 0
      end
    end

    test "номиналы не убывают" do
      blinds = Enum.map(Grid.blind_levels(:regular), & &1.big_blind)

      assert blinds == Enum.sort(blinds)
    end
  end

  describe "сетка выплат" do
    test "проходит проверку ядра для всей возможной явки" do
      rows = Enum.map(Grid.payouts(), &to_row/1)

      assert TournamentPayout.validate(rows, 2, 1000) == :ok
    end

    test "сумма выплат равна фонду при любой явке" do
      rows = Enum.map(Grid.payouts(), &to_row/1)

      for entries <- [2, 5, 9, 10, 29, 30, 99, 100, 500] do
        payouts = TournamentPayout.compute(rows, entries, entries, 1_000_003)

        assert TournamentPayout.total(payouts) == 1_000_003,
               "фонд разошёлся при явке #{entries}"
      end
    end

    test "чем больше явка, тем больше оплачиваемых мест" do
      rows = Enum.map(Grid.payouts(), &to_row/1)

      places =
        for entries <- [5, 20, 50, 300], do: TournamentPayout.paid_places(rows, entries, entries)

      assert places == [2, 3, 6, 18]
      assert places == Enum.sort(places)
    end

    test "доля первого места падает с ростом явки" do
      rows = Enum.map(Grid.payouts(), &to_row/1)

      firsts =
        for entries <- [5, 20, 50, 300] do
          rows
          |> TournamentPayout.compute(entries, entries, 1_000_000)
          |> hd()
          |> Map.fetch!(:amount)
        end

      assert firsts == Enum.sort(firsts, :desc)
    end
  end

  describe "шаблоны" do
    test "разворачиваются по трём осям" do
      rows = Grid.rows()

      # Две валюты × цены × три скорости.
      assert length(rows) == 21
    end

    test "фильтр по валюте сужает набор" do
      assert Enum.all?(Grid.rows(currency: :main), &(&1.attrs.currency == :main))
    end

    test "комиссия не входит во взнос" do
      for row <- Grid.rows() do
        assert row.attrs.entry_fee > 0
        assert row.attrs.entry_fee < row.attrs.buy_in
      end
    end

    test "у каждого шаблона есть расписание" do
      for row <- Grid.rows() do
        assert [%{start_time: %Time{}}] = row.schedules
      end
    end

    test "имена уникальны: иначе естественный ключ схлопнул бы шаблоны" do
      names = Enum.map(Grid.rows(), & &1.attrs.name)

      assert names == Enum.uniq(names)
    end
  end

  defp to_row(row) do
    row
    |> Map.put(:ticket_id, nil)
    |> Map.put(:ticket_value, nil)
  end
end
