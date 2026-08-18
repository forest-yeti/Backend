defmodule BlockPoker.Engine.EquityTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BlockPoker.Engine.{Card, Equity, Rng, Variant}

  @holdem Variant.TexasHoldem

  defp hand(string), do: Card.parse_many!(string)
  defp player(result, id), do: Enum.find(result.players, &(&1.id == id))

  describe "выбор режима" do
    test "ривер, тёрн и флоп считаются точно" do
      hands = [{:alice, hand("AS AD")}, {:bob, hand("KS KD")}]

      assert Equity.equity(hands, hand("2C 7H 9S TD 3C"), @holdem).mode == :exact
      assert Equity.equity(hands, hand("2C 7H 9S TD"), @holdem).simulations == 44
      assert Equity.equity(hands, hand("2C 7H 9S"), @holdem).simulations == 990
    end

    test "префлоп уходит в Монте-Карло" do
      result =
        Equity.equity([{:alice, hand("AS AD")}, {:bob, hand("KS KD")}], [], @holdem,
          iterations: 500,
          rng: Rng.seeded("режим")
        )

      assert result.mode == :monte_carlo
      assert result.simulations == 500
    end

    test "порог точного перебора настраивается" do
      hands = [{:alice, hand("AS AD")}, {:bob, hand("KS KD")}]

      assert Equity.equity(hands, hand("2C 7H 9S"), @holdem, threshold: 100).mode == :monte_carlo
    end

    test "точный режим на неизвестных руках невозможен" do
      assert_raise ArgumentError, fn ->
        Equity.equity([{:alice, hand("AS AD")}, {:bob, :unknown}], hand("2C 7H 9S"), @holdem,
          mode: :exact
        )
      end
    end
  end

  describe "известные сценарии" do
    test "AA против KK на пустом борде — примерно 83 на 17" do
      result =
        Equity.equity([{:alice, hand("AS AD")}, {:bob, hand("KS KD")}], [], @holdem,
          iterations: 20_000,
          rng: Rng.seeded("AAvsKK")
        )

      # Точный перебор C(48,5) даёт 0.8264 против 0.1736 — Монте-Карло обязано
      # попасть туда же. Ходовое «81 на 19» — это средняя по мастям пары рук,
      # а конкретные AsAd против KsKd стоят чуть дороже.
      assert_in_delta player(result, :alice).equity, 0.8264, 0.01
      assert_in_delta player(result, :bob).equity, 0.1736, 0.01
    end

    test "два оверкарта против пары на флопе" do
      # AK против QQ на борде 2-7-9: пара впереди, у AK шесть аутов.
      result =
        Equity.equity(
          [{:alice, hand("QS QD")}, {:bob, hand("AH KS")}],
          hand("2C 7D 9S"),
          @holdem
        )

      assert result.mode == :exact
      assert_in_delta player(result, :alice).equity, 0.76, 0.03
      assert_in_delta player(result, :bob).equity, 0.24, 0.03
    end

    test "флеш-дро против пары на флопе" do
      result =
        Equity.equity(
          [{:alice, hand("AH KH")}, {:bob, hand("9S 9D")}],
          hand("2H 7H TC"),
          @holdem
        )

      assert_in_delta player(result, :alice).equity, 0.53, 0.03
      assert_in_delta player(result, :bob).equity, 0.47, 0.03
    end

    test "выигранный на ривере банк — это 100% эквити" do
      result =
        Equity.equity(
          [{:alice, hand("AS AD")}, {:bob, hand("KS KD")}],
          hand("2C 7H 9S TD 3C"),
          @holdem
        )

      assert player(result, :alice).equity == 1.0
      assert player(result, :bob).equity == 0.0
      assert result.simulations == 1
    end

    test "ничья считается долей банка, а не победой" do
      result =
        Equity.equity(
          [{:alice, hand("2C 3D")}, {:bob, hand("2H 3S")}],
          hand("AS AD AC AH KS"),
          @holdem
        )

      assert player(result, :alice) == %{
               id: :alice,
               win: 0.0,
               tie: 1.0,
               equity: 0.5,
               outs: []
             }
    end
  end

  describe "мёртвые карты" do
    test "изъятая карта не выходит на борд" do
      # Единственный аут bob — король; изымем два из них.
      hands = [{:alice, hand("AS AD")}, {:bob, hand("KS KD")}]
      board = hand("2C 7H 9S TD")

      full = Equity.equity(hands, board, @holdem)
      dead = Equity.equity(hands, board, @holdem, dead_cards: hand("KH KC"))

      assert full.simulations == 44
      assert dead.simulations == 42
      assert player(full, :bob).equity > 0
      assert player(dead, :bob).equity == 0
    end
  end

  describe "неизвестные руки" do
    test "считаются только Монте-Карло и дают осмысленный результат" do
      result =
        Equity.equity([{:alice, hand("AS AD")}, {:bob, :unknown}], hand("2C 7H 9S"), @holdem,
          iterations: 2_000,
          rng: Rng.seeded("unknown")
        )

      assert result.mode == :monte_carlo
      assert player(result, :alice).equity > 0.7
      assert_in_delta player(result, :alice).equity + player(result, :bob).equity, 1.0, 1.0e-9
    end
  end

  describe "воспроизводимость" do
    test "один seed — один результат" do
      hands = [{:alice, hand("AS AD")}, {:bob, hand("KS KD")}]

      left = Equity.equity(hands, [], @holdem, iterations: 3_000, rng: Rng.seeded("повтор"))
      right = Equity.equity(hands, [], @holdem, iterations: 3_000, rng: Rng.seeded("повтор"))

      assert left == right
    end

    test "параллельный и последовательный счёт с одним seed совпадают" do
      hands = [{:alice, hand("AS AD")}, {:bob, hand("KS KD")}]

      parallel = Equity.equity(hands, [], @holdem, iterations: 3_000, rng: Rng.seeded("чанки"))

      sequential =
        Equity.equity(hands, [], @holdem,
          iterations: 3_000,
          rng: Rng.seeded("чанки"),
          parallel: false
        )

      assert_in_delta player(parallel, :alice).equity, player(sequential, :alice).equity, 0.02
    end

    test "точный режим и Монте-Карло сходятся" do
      hands = [{:alice, hand("AH KH")}, {:bob, hand("9S 9D")}]
      board = hand("2H 7H TC")

      exact = Equity.equity(hands, board, @holdem, mode: :exact)

      approximate =
        Equity.equity(hands, board, @holdem,
          mode: :monte_carlo,
          iterations: 30_000,
          rng: Rng.seeded("сходимость")
        )

      assert_in_delta player(exact, :alice).equity, player(approximate, :alice).equity, 0.01
    end
  end

  describe "искусственный вариант" do
    test "эквити считается по чужим правилам без правок в lib" do
      result =
        Equity.equity(
          [{:alice, hand("AH KH QH")}, {:bob, hand("9S 9D 5C")}],
          hand("JH TH 9H"),
          Variant.Artificial
        )

      assert result.mode == :exact

      # Одна неизвестная карта борда из 40 - 3 - 3 - 3 = 31 оставшихся.
      assert result.simulations == 31
      assert player(result, :alice).equity == 1.0
    end
  end

  property "сумма эквити всех игроков равна единице" do
    check all(
            cards <- StreamData.uniq_list_of(StreamData.integer(0..51), length: 7),
            max_runs: 25
          ) do
      [a, b, c, d, board_one, board_two, board_three] = cards

      result =
        Equity.equity(
          [{:alice, [a, b]}, {:bob, [c, d]}],
          [board_one, board_two, board_three],
          @holdem
        )

      total = result.players |> Enum.map(& &1.equity) |> Enum.sum()
      assert_in_delta total, 1.0, 1.0e-9
    end
  end

  property "эквити не зависит от порядка игроков" do
    check all(
            cards <- StreamData.uniq_list_of(StreamData.integer(0..51), length: 8),
            max_runs: 25
          ) do
      [a, b, c, d | board] = cards
      hands = [{:alice, [a, b]}, {:bob, [c, d]}]

      direct = Equity.equity(hands, board, @holdem)
      reversed = Equity.equity(Enum.reverse(hands), board, @holdem)

      assert_in_delta player(direct, :alice).equity, player(reversed, :alice).equity, 1.0e-9
    end
  end

  property "win и tie не пересекаются и не превышают единицы" do
    check all(
            cards <- StreamData.uniq_list_of(StreamData.integer(0..51), length: 8),
            max_runs: 25
          ) do
      [a, b, c, d | board] = cards

      result = Equity.equity([{:alice, [a, b]}, {:bob, [c, d]}], board, @holdem)

      assert Enum.all?(result.players, fn player ->
               player.win >= 0 and player.tie >= 0 and player.win + player.tie <= 1.0
             end)
    end
  end
end
