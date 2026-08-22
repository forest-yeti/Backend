defmodule BlockPoker.Engine.Ofc.HandTest do
  @moduledoc """
  Ход раздачи китайского покера: сдачи, очередь, колода, расчёт и фантазия.

  Без БД и без процессов. Раздача доигрывается автораскладкой — она же и
  проверяется заодно: если `Autoplace` фолит там, где мог не фолить, это
  видно по итогам.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BlockPoker.Engine.{HandSetup, Rng}
  alias BlockPoker.Engine.Ofc.{Autoplace, Board, Hand}
  alias BlockPoker.Engine.Variant.TexasHoldem

  defp setup_hand(seats, opts \\ []) do
    players =
      Enum.map(seats, fn {seat, stack} ->
        %{
          seat: seat,
          id: "user-#{seat}",
          stack: stack,
          post: 0,
          dead_post: 0,
          fantasy: seat in Keyword.get(opts, :fantasy, [])
        }
      end)

    setup = %HandSetup{
      variant: TexasHoldem,
      players: players,
      button_seat: elem(hd(seats), 0),
      point_value: Keyword.get(opts, :point_value, 10)
    }

    Hand.start(setup, Rng.seeded(Keyword.get(opts, :seed, "ofc")), [])
  end

  # Доигрывает раздачу автораскладкой: она и есть ход стола за игрока.
  defp play_out({hand, events}), do: play_out(hand, events)

  defp play_out(hand, events) do
    case Hand.to_act(hand) do
      nil ->
        {hand, events}

      seat ->
        {placements, discard} = auto(hand, seat)
        {:ok, hand, more} = Hand.act(hand, seat, {:place, placements, discard}, Hand.seq(hand))
        play_out(hand, events ++ more)
    end
  end

  defp auto(hand, seat) do
    %{deal: {:cards, cards}, legal_actions: legal} = Hand.private_view(hand, seat)
    board = board_of(hand, seat)

    Autoplace.choose(board, cards, legal.discard, TexasHoldem)
  end

  defp board_of(hand, seat) do
    %{rows: rows} = hand |> Hand.public_view() |> get_in([:seats, seat])

    Enum.reduce(Board.rows(), Board.new(), fn row, board ->
      {:cards, cards} = rows[row]
      Map.put(board, row, cards)
    end)
  end

  describe "ход раздачи" do
    test "первая сдача — пять карт и ни одного сброса" do
      {hand, _events} = setup_hand([{1, 1000}, {2, 1000}])

      assert Hand.to_act(hand) == 2
      %{deal: {:cards, cards}, legal_actions: legal} = Hand.private_view(hand, 2)

      assert length(cards) == 5
      assert legal.place == 5
      assert legal.discard == 0
    end

    test "круги — три карты, две в боксы и одна в сброс" do
      {hand, _events} = setup_hand([{1, 1000}, {2, 1000}])

      # Обе первые сдачи разложены — начинается первый круг.
      {hand, _events} = play_first_deals(hand)

      %{deal: {:cards, cards}, legal_actions: legal} = Hand.private_view(hand, Hand.to_act(hand))

      assert length(cards) == 3
      assert legal.place == 2
      assert legal.discard == 1
    end

    test "тринадцать карт на игрока и четыре сброса" do
      {hand, _events} = play_out(setup_hand([{1, 1000}, {2, 1000}, {3, 1000}]))

      Enum.each([1, 2, 3], fn seat ->
        %{seats: seats} = Hand.public_view(hand)
        assert seats[seat].placed == 13
        assert seats[seat].discarded == 4
      end)
    end

    test "роспись боксов приходит только у собранных" do
      {start, _events} = setup_hand([{1, 1000}, {2, 1000}])
      seat = Hand.to_act(start)

      # До хода не собран ни один бокс: расписывать нечего, и придумывать
      # категорию неполной руке нельзя.
      assert %{top: nil, middle: nil, bottom: nil} =
               Hand.public_view(start).seats[seat].combinations

      {hand, _events} = play_out({start, []})
      %{seats: seats} = Hand.public_view(hand)

      # По концу раскладки расписаны все три: клиент берёт категорию отсюда,
      # а не считает её сам — это правило варианта, а не оформление.
      for {_seat, view} <- seats do
        assert %{top: top, middle: middle, bottom: bottom} = view.combinations
        assert top != nil
        assert middle != nil
        assert bottom != nil
      end

      assert %{combinations: %{bottom: bottom}} = Hand.private_view(hand, seat)
      assert bottom != nil
    end

    test "51 сданная карта при троих попарно различна" do
      {hand, events} = play_out(setup_hand([{1, 1000}, {2, 1000}, {3, 1000}]))

      dealt =
        Enum.flat_map(events, fn
          {:deal, %{cards: cards}} -> cards
          _event -> []
        end)

      assert length(dealt) == 51
      assert length(Enum.uniq(dealt)) == 51
      assert Hand.progress(hand) == :finished
    end
  end

  describe "порядок хода" do
    test "фантазийный игрок ходит первым и одним ходом" do
      {hand, _events} = setup_hand([{1, 1000}, {2, 1000}], fantasy: [1])

      assert Hand.to_act(hand) == 1
      %{deal: {:cards, cards}, legal_actions: legal} = Hand.private_view(hand, 1)

      assert length(cards) == 14
      assert legal.place == 13
      assert legal.discard == 1

      {placements, discard} = auto(hand, 1)
      {:ok, hand, _events} = Hand.act(hand, 1, {:place, placements, discard}, Hand.seq(hand))

      # Рука выложена целиком, дальше круги идут только между обычными.
      assert Hand.public_view(hand).seats[1].placed == 13
      assert Hand.to_act(hand) == 2
    end

    test "соперник не видит ни карт фантазии до вскрытия, ни чужих сбросов" do
      {hand, _events} = setup_hand([{1, 1000}, {2, 1000}], fantasy: [1])

      view = Hand.public_view(hand)

      # До хода фантазийного игрока его боксы пусты, а руки в публичной
      # части нет вовсе — как и сбросов у кого угодно.
      assert view.seats[1].placed == 0
      refute Map.has_key?(view.seats[1], :hand)
      refute Map.has_key?(view.seats[1], :discards)
      assert Hand.private_view(hand, 2).deal == {:cards, []}
    end
  end

  describe "отклонение хода" do
    test "чужая карта, переполненный бокс и неверное число размещений" do
      {hand, _events} = setup_hand([{1, 1000}, {2, 1000}])
      seat = Hand.to_act(hand)
      %{deal: {:cards, cards}} = Hand.private_view(hand, seat)
      [a, b, c, d, e] = cards

      alien = Enum.find(0..51, &(&1 not in cards))

      assert {:error, :invalid_placement} =
               Hand.act(
                 hand,
                 seat,
                 {:place, [{alien, :top} | Enum.map([b, c, d, e], &{&1, :bottom})], nil},
                 nil
               )

      assert {:error, :invalid_placement} =
               Hand.act(hand, seat, {:place, Enum.map(cards, &{&1, :top}), nil}, nil)

      assert {:error, :invalid_placement} =
               Hand.act(hand, seat, {:place, [{a, :top}, {b, :top}], nil}, nil)
    end

    test "не своя очередь и устаревший action_seq" do
      {hand, _events} = setup_hand([{1, 1000}, {2, 1000}])
      seat = Hand.to_act(hand)
      other = if seat == 1, do: 2, else: 1
      %{deal: {:cards, cards}} = Hand.private_view(hand, seat)
      placements = Enum.map(cards, &{&1, :bottom})

      assert {:error, :not_your_turn} =
               Hand.act(hand, other, {:place, placements, nil}, nil)

      assert {:error, :stale_action} =
               Hand.act(hand, seat, {:place, placements, nil}, Hand.seq(hand) + 7)
    end
  end

  describe "расчёт" do
    property "фишки за столом не появляются и не исчезают" do
      check all(
              seed <- string(:alphanumeric, min_length: 1, max_length: 8),
              stacks <- list_of(integer(0..2000), length: 3),
              max_runs: 25
            ) do
        [a, b, c] = stacks
        seats = [{1, a}, {2, b}, {3, c}]

        {hand, _events} = play_out(setup_hand(seats, seed: seed))

        players = Hand.players(hand)
        assert players |> Map.values() |> Enum.map(& &1.stack) |> Enum.sum() == a + b + c
        assert Enum.all?(players, fn {_seat, player} -> player.stack >= 0 end)
      end
    end

    property "сумма очков всех участников равна нулю" do
      check all(seed <- string(:alphanumeric, min_length: 1, max_length: 8), max_runs: 25) do
        {hand, _events} = play_out(setup_hand([{1, 5000}, {2, 5000}, {3, 5000}], seed: seed))

        assert hand |> Hand.results() |> Map.fetch!(:scores) |> Map.values() |> Enum.sum() == 0
      end
    end

    test "стека не хватает — перенос урезан, а стол не уходит в минус" do
      {hand, _events} = play_out(setup_hand([{1, 10}, {2, 5000}, {3, 5000}], point_value: 100))

      players = Hand.players(hand)

      assert Enum.all?(players, fn {_seat, player} -> player.stack >= 0 end)
      assert players |> Map.values() |> Enum.map(& &1.stack) |> Enum.sum() == 10_010
    end
  end

  describe "автораскладка" do
    property "не убивает руку там, где её можно не убить" do
      # Формулировка §7 задачи — про **текущий ход**, а не про всю раздачу:
      # к последнему кругу карты уже выложены, и фол может быть неизбежен
      # при любом размещении. Проверяется ровно обещанное: если непроигрышное
      # размещение существует, правило обязано его найти.
      check all(
              placed <- uniq_list_of(integer(0..51), min_length: 0, max_length: 8),
              deal <- uniq_list_of(integer(0..51), length: 3),
              max_runs: 50
            ) do
        deal = deal -- placed

        if length(deal) == 3 do
          board = fill(placed)

          {placements, discard} = Autoplace.choose(board, deal, 1, TexasHoldem)

          assert length(placements) == 2
          assert discard in deal
          {:ok, next} = Board.place(board, placements)

          unless Board.dead?(next, TexasHoldem) do
            assert true
          else
            # Раз выбранная ветка мёртвая, живой не существовало вовсе.
            refute Enum.any?(alternatives(board, deal), &(not Board.dead?(&1, TexasHoldem)))
          end
        end
      end
    end
  end

  # Раскладка, набранная снизу вверх: боксы заполняются по мере карт, чтобы
  # генератор давал именно частично собранные руки.
  defp fill(cards) do
    Enum.reduce(cards, Board.new(), fn card, board ->
      row = Enum.find(Board.rows(), &(Board.free(board, &1) > 0))
      {:ok, board} = Board.place(board, [{card, row}])
      board
    end)
  end

  # Все размещения этой сдачи: по одной сброшенной карте и всем способам
  # разложить оставшиеся две.
  defp alternatives(board, deal) do
    for dropped <- deal,
        [a, b] = deal -- [dropped],
        first <- Board.rows(),
        second <- Board.rows(),
        reduce: [] do
      acc ->
        case Board.place(board, [{a, first}, {b, second}]) do
          {:ok, next} -> [next | acc]
          {:error, _reason} -> acc
        end
    end
  end

  defp play_first_deals(hand) do
    Enum.reduce(1..2, {hand, []}, fn _step, {hand, events} ->
      seat = Hand.to_act(hand)
      {placements, discard} = auto(hand, seat)
      {:ok, hand, more} = Hand.act(hand, seat, {:place, placements, discard}, nil)
      {hand, events ++ more}
    end)
  end
end
