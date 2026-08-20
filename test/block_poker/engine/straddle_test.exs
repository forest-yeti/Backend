defmodule BlockPoker.Engine.StraddleTest do
  @moduledoc """
  Страддл: ставка вслепую до карт.

  Проверяется ровно то, что легко сломать частным случаем, — деньги, номинал
  круга и очередь хода. Инвариант «фишки не возникают и не исчезают» здесь
  особенно уместен: страддл ставится до карт и мимо обычного пути ставок.
  """

  use ExUnit.Case, async: true

  alias BlockPoker.Engine.{Hand, HandSetup, Rng, Straddle}
  alias BlockPoker.Engine.Variant.{ShortDeck, TexasHoldem}

  defp setup_hand(stacks, opts) do
    players =
      stacks
      |> Enum.with_index(1)
      |> Enum.map(fn {stack, seat} ->
        %{seat: seat, id: "p#{seat}", stack: stack, post: 0, dead_post: 0}
      end)

    %HandSetup{
      variant: Keyword.get(opts, :variant, TexasHoldem),
      players: players,
      button_seat: Keyword.get(opts, :button, 1),
      small_blind: 5,
      big_blind: 10,
      ante: Keyword.get(opts, :ante, 0),
      ante_type: Keyword.get(opts, :ante_type, :big_blind),
      straddle: Keyword.get(opts, :straddle)
    }
  end

  defp start(stacks, opts \\ []) do
    setup = setup_hand(stacks, opts)
    {hand, events} = Hand.start(setup, Rng.seeded(<<7::256>>))
    assert Hand.total_chips(hand) == HandSetup.total_chips(setup)
    {hand, events}
  end

  defp posted(events, kind) do
    Enum.find(events, fn
      {:posted, %{kind: ^kind}} -> true
      _other -> false
    end)
  end

  describe "границы суммы" do
    test "минимум — два номинала стола" do
      assert Straddle.min_amount(10) == 20
      assert Straddle.min_amount(100) == 200
    end

    test "меньше минимума не принимается" do
      assert {:error, :invalid_straddle} = Straddle.normalize(19, 10, 1000)
      assert {:ok, 20} = Straddle.normalize(20, 10, 1000)
    end

    test "заявка сверх стека — это олл-ин вслепую, а не ошибка" do
      assert {:ok, 400} = Straddle.normalize(10_000, 10, 400)
    end

    test "короткому стеку страддл недоступен вовсе" do
      refute Straddle.available?(19, 10)
      assert {:error, :straddle_unavailable} = Straddle.normalize(19, 10, 19)
    end

    test "мусор вместо суммы отвергается" do
      assert {:error, :invalid_straddle} = Straddle.normalize(0, 10, 1000)
      assert {:error, :invalid_straddle} = Straddle.normalize(-100, 10, 1000)
      assert {:error, :invalid_straddle} = Straddle.normalize("много", 10, 1000)
    end
  end

  describe "выбор одной заявки из нескольких" do
    # Порядок хода от кнопки: кнопка в списке последняя, и она же — лучшая
    # позиция за столом.
    @order [2, 3, 4, 1]

    test "побеждает большая сумма" do
      intents = [%{seat: 2, amount: 100}, %{seat: 4, amount: 300}]
      assert %{seat: 4, amount: 300} = Straddle.choose(intents, @order)
    end

    test "при равных суммах — ближайший к кнопке" do
      intents = [%{seat: 2, amount: 100}, %{seat: 4, amount: 100}, %{seat: 1, amount: 100}]
      assert %{seat: 1} = Straddle.choose(intents, @order)
    end

    test "заявок нет — страддла нет" do
      assert Straddle.choose([], @order) == nil
    end
  end

  describe "постановка в раздаче" do
    test "страддл становится ставкой круга, и торговля идёт от него" do
      {hand, events} = start([1000, 1000, 1000], button: 1, straddle: %{seat: 2, amount: 100})

      # Место 2 — малый блайнд: в событии стоит доплата, а вложено ровно
      # столько, сколько объявлено.
      assert {:posted, %{seat: 2, amount: 95}} = posted(events, "straddle")
      assert Map.fetch!(hand.players, 2).committed == 100
      assert hand.bet == 100

      # Номинал круга — страддл: минимальный рейз считается от него, а не
      # от большого блайнда.
      assert hand.bet_unit == 100
      assert hand.min_raise == 100

      %{raise: %{min: min}} = Hand.legal_actions(hand, hand.to_act)
      assert min == 200
    end

    test "порядок хода не меняется: первым говорит тот же, кто и без страддла" do
      {without, _events} = start([1000, 1000, 1000], button: 1)

      {with_straddle, _events} =
        start([1000, 1000, 1000], button: 1, straddle: %{seat: 3, amount: 100})

      assert without.to_act == with_straddle.to_act
    end

    test "страддлер права переспросить не получает: уравняли — раздача идёт дальше" do
      # Кнопка (место 1) страддлит, малый и большой блайнды уравнивают.
      # Без `option?: false` кнопка получила бы лишний ход на уравненной
      # ставке и префлоп не закрылся бы.
      {hand, _events} = start([1000, 1000, 1000], button: 1, straddle: %{seat: 1, amount: 100})

      {:ok, hand, _} = Hand.act(hand, hand.to_act, :call, nil)
      {:ok, hand, _} = Hand.act(hand, hand.to_act, :call, nil)

      assert hand.street == :flop
    end

    test "страддливший блайнд доплачивает разницу, а не ставит страддл сверху" do
      # Место 3 — большой блайнд (кнопка на 1). Оно же страддлит на 100:
      # в банке должно оказаться 100 с этого места, а не 110.
      {hand, _events} = start([1000, 1000, 1000], button: 1, straddle: %{seat: 3, amount: 100})

      assert Map.fetch!(hand.players, 3).committed == 100
      assert Map.fetch!(hand.players, 3).stack == 900
    end

    test "олл-ин вслепую: страддлер выбывает из торговли, деньги на месте" do
      {hand, _events} = start([1000, 1000, 300], button: 1, straddle: %{seat: 3, amount: 300})

      assert Map.fetch!(hand.players, 3).status == :all_in
      assert hand.bet == 300
      assert hand.pot == 305
    end

    test "Short Deck: минимум — два анте, и страддл живой так же" do
      {hand, events} =
        start([1000, 1000, 1000],
          variant: ShortDeck,
          ante: 10,
          button: 1,
          straddle: %{seat: 2, amount: 20}
        )

      assert {:posted, %{seat: 2, amount: 20}} = posted(events, "straddle")
      assert hand.bet == 20
      assert hand.bet_unit == 20
    end

    test "без страддла раздача идёт ровно как раньше" do
      {hand, events} = start([1000, 1000, 1000], button: 1)

      assert posted(events, "straddle") == nil
      assert hand.bet == 10
      assert hand.bet_unit == 10
    end
  end
end
