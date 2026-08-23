defmodule BlockPoker.Engine.EliminationTest do
  @moduledoc """
  Места вылетевших, включая раздачу, которая выбивает нескольких сразу.

  Тайбрейк по стеку на начало раздачи — стандарт, и он единственный,
  который не зависит от порядка разрешения банков. При равных стеках
  места делятся: отдать более высокое по номеру сиденья значило бы
  решить деньгами то, что игра не решила.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BlockPoker.Engine.Elimination

  @table %{button_seat: 1, table_size: 6}

  defp victim(id, stack, seat \\ 2) do
    %{entry_id: id, seat: seat, stack_before: stack}
  end

  describe "одиночный вылет" do
    test "место равно числу выживших плюс один" do
      assert [%{entry_id: :v, place: 21}] = Elimination.assign([victim(:v, 100)], 20, @table)
    end

    test "последний выбывший из двоих занимает второе место" do
      assert [%{place: 2}] = Elimination.assign([victim(:v, 100)], 1, @table)
    end

    test "одиночный вылет ни с кем не делится" do
      [placement] = Elimination.assign([victim(:v, 100)], 5, @table)

      assert placement.shared_places == [placement.place]
      assert placement.tied_with == []
    end

    test "пустой список вылетов не порождает мест" do
      assert Elimination.assign([], 5, @table) == []
    end
  end

  describe "несколько выбитых одной раздачей" do
    test "больший стек занимает более высокое место" do
      victims = [victim(:small, 10, 2), victim(:big, 900, 4)]

      places = Elimination.assign(victims, 5, @table)

      assert Enum.find(places, &(&1.entry_id == :big)).place == 6
      assert Enum.find(places, &(&1.entry_id == :small)).place == 7
    end

    test "трое выбитых занимают три подряд идущих места" do
      victims = [victim(:a, 300, 2), victim(:b, 200, 3), victim(:c, 100, 4)]

      places = Elimination.assign(victims, 3, @table)

      assert Enum.map(places, & &1.place) == [4, 5, 6]
      assert Enum.map(places, & &1.entry_id) == [:a, :b, :c]
    end
  end

  describe "равные стеки" do
    test "места связываются, а не раздаются по номеру сиденья" do
      victims = [victim(:a, 100, 2), victim(:b, 100, 5)]

      places = Elimination.assign(victims, 4, @table)

      assert Enum.all?(places, &(&1.shared_places == [5, 6]))
      assert Enum.find(places, &(&1.entry_id == :a)).tied_with == [:b]
    end

    test "порядок внутри связки задаёт близость к кнопке" do
      # Кнопка на месте 1: место 2 ближе к ней, чем место 5.
      victims = [victim(:far, 100, 5), victim(:near, 100, 2)]

      places = Elimination.assign(victims, 4, @table)

      assert hd(places).entry_id == :near
    end

    test "равные и неравные стеки в одной раздаче разбираются вместе" do
      victims = [victim(:big, 500, 2), victim(:a, 100, 3), victim(:b, 100, 4)]

      places = Elimination.assign(victims, 2, @table)

      assert Enum.find(places, &(&1.entry_id == :big)).shared_places == [3]
      assert Enum.find(places, &(&1.entry_id == :a)).shared_places == [4, 5]
    end
  end

  describe "деление приза связанных мест" do
    test "делится поровну" do
      assert Elimination.split_prize(1000, 2) == [500, 500]
    end

    test "остаток достаётся первому по тайбрейку" do
      assert Elimination.split_prize(1001, 2) == [501, 500]
    end

    test "трое делят с остатком" do
      assert Elimination.split_prize(1000, 3) == [334, 333, 333]
    end

    test "нулевой приз делится в нули" do
      assert Elimination.split_prize(0, 3) == [0, 0, 0]
    end
  end

  describe "инварианты" do
    property "места идут подряд от числа выживших плюс один" do
      check all(
              stacks <- list_of(integer(0..1000), min_length: 1, max_length: 9),
              survivors <- integer(0..100)
            ) do
        victims =
          stacks
          |> Enum.with_index()
          |> Enum.map(fn {stack, index} -> victim({:v, index}, stack, rem(index, 6) + 1) end)

        places = victims |> Elimination.assign(survivors, @table) |> Enum.map(& &1.place)

        assert places == Enum.to_list((survivors + 1)..(survivors + length(stacks)))
      end
    end

    property "каждый выбывший получает ровно одно место" do
      check all(stacks <- list_of(integer(0..1000), min_length: 1, max_length: 9)) do
        victims =
          stacks
          |> Enum.with_index()
          |> Enum.map(fn {stack, index} -> victim({:v, index}, stack, rem(index, 6) + 1) end)

        placements = Elimination.assign(victims, 3, @table)
        ids = Enum.map(placements, & &1.entry_id)

        assert length(placements) == length(stacks)
        assert ids == Enum.uniq(ids)
      end
    end

    property "делёж приза раздаёт сумму целиком" do
      check all(total <- integer(0..1_000_000), count <- integer(1..9)) do
        assert Enum.sum(Elimination.split_prize(total, count)) == total
      end
    end
  end
end
