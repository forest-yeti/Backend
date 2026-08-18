defmodule BlockPoker.Engine.EntryRulesTest do
  @moduledoc """
  Вход в игру (§6 задачи 3). Правило денежное, поэтому проверяется на уровне
  ядра: без комнаты, без БД.
  """

  use ExUnit.Case, async: true

  alias BlockPoker.Engine.EntryRules

  @seats [1, 2, 3, 4, 5, 6]

  defp params(overrides) do
    Map.merge(
      %{
        seat: 5,
        intent: :wait_bb,
        seats_in_game: @seats,
        button_seat: 1,
        big_blind_seat: 3,
        big_blind: 20,
        heads_up?: false,
        allow_post_blind?: true,
        missed_blinds: 0,
        dodging?: false
      },
      Map.new(overrides)
    )
  end

  test "по умолчанию севший игрок ждёт большого блайнда и ничего не платит" do
    decision = EntryRules.decide(params(%{}))

    assert decision.status == :waiting_for_bb
    assert decision.post == 0
    assert decision.dead_post == 0
  end

  test "сев на большой блайнд, игрок вступает немедленно" do
    assert EntryRules.decide(params(%{seat: 3})).status == :playing
  end

  test "сев сразу за большим блайндом, игрок вступает немедленно" do
    assert EntryRules.decide(params(%{seat: 4})).status == :playing
  end

  test "на хедз-апе ожидания нет вовсе" do
    decision = EntryRules.decide(params(%{heads_up?: true, seats_in_game: [1, 2], seat: 2}))

    assert decision.status == :playing
  end

  test "игра ещё не идёт — вступление немедленное" do
    decision = EntryRules.decide(params(%{button_seat: nil, big_blind_seat: nil}))

    assert decision.status == :playing
  end

  describe "вход за post" do
    test "после большого блайнда взнос живой: он же ставка игрока" do
      decision = EntryRules.decide(params(%{intent: :post, seat: 5}))

      assert decision.status == :playing
      assert decision.post == 20
      assert decision.dead_post == 0
    end

    test "между кнопкой и большим блайндом взнос мёртвый" do
      # Место 2 стоит между кнопкой (1) и большим блайндом (3): круг блайндов
      # в этой раздаче игрок пропускает, значит его взнос уходит в банк,
      # но ставкой не считается и права чека не даёт.
      decision = EntryRules.decide(params(%{intent: :post, seat: 2}))

      assert decision.status == :playing
      assert decision.post == 0
      assert decision.dead_post == 20
    end

    test "пропущенные блайнды доплачиваются вместе со взносом" do
      decision = EntryRules.decide(params(%{intent: :post, seat: 5, missed_blinds: 1}))

      assert decision.post == 40
    end

    test "при allow_post_blind: false вход за post невозможен" do
      decision = EntryRules.decide(params(%{intent: :post, allow_post_blind?: false}))

      assert decision.status == :waiting_for_bb
      assert decision.post == 0
      refute decision.can_post
    end
  end

  describe "окно возврата" do
    test "повторная посадка внутри окна не даёт права ждать блайнда" do
      decision = EntryRules.decide(params(%{dodging?: true}))

      assert decision.status == :post_required
      assert decision.can_post
    end

    test "но при запрещённом post игрок всё равно ждёт блайнда" do
      decision = EntryRules.decide(params(%{dodging?: true, allow_post_blind?: false}))

      assert decision.status == :waiting_for_bb
    end
  end

  describe "dead_post?/4" do
    test "места между кнопкой и большим блайндом — мёртвая зона" do
      assert EntryRules.dead_post?(2, 1, 3, @seats)
      refute EntryRules.dead_post?(4, 1, 3, @seats)
      refute EntryRules.dead_post?(1, 1, 3, @seats)
    end

    test "зона считается по кругу, а не по номерам мест" do
      # Кнопка на 5, большой блайнд на 1: между ними место 6.
      assert EntryRules.dead_post?(6, 5, 1, @seats)
      refute EntryRules.dead_post?(3, 5, 1, @seats)
    end
  end
end
