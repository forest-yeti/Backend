defmodule BlockPoker.Engine.Equity do
  @moduledoc """
  Эквити и ауты в момент all-in.

  Сценарий ровно один: торговля завершена, оставшиеся игроки в all-in, карты
  вскрыты, идёт раздача борда. Пока кто-то ещё принимает решения, эквити не
  считается — проценты раскрыли бы силу рук тем, кто ещё не сходил. Само
  правило «когда показывать» — не дело калькулятора: он чистая функция, а
  состоянием стола владеет `TableServer`.

  Отсюда следует главное для реализации: все руки известны. `:unknown`
  оставлен ради тестов и разбора истории и считается только Монте-Карло.

  Режим выбирается числом неизвестных карт: ривер, тёрн и флоп перебираются
  точно (1, 44 и 990 раскладов), префлоп — `C(48,5)` ≈ 1.7 млн раскладов,
  что при наивной оценке даёт десятки миллионов вычислений и в бюджет §8
  не влезает, поэтому уходит в Монте-Карло. Погрешность 100 000 итераций
  порядка ±0.15 п.п. — при отображении целых процентов невидима.

  Сброшенные карты в расчёт не берутся: они остаются в колоде обычными
  неизвестными. `:dead_cards` — про карты, гарантированно не выходящие
  (засвеченные, изъятые), по умолчанию пуст.
  """

  alias BlockPoker.Engine.{
    Card,
    CardSet,
    Combinatorics,
    EquityResult,
    HandRank,
    Outs,
    Rng,
    Variant
  }

  @type player_id :: term()
  @type hand_spec :: {player_id(), [Card.t()] | :unknown}

  @default_iterations 100_000
  @exact_threshold 200_000

  @doc """
  Эквити каждого игрока и его ауты.

  Опции:

    * `:mode` — `:auto` (по умолчанию), `:exact` или `:monte_carlo`;
    * `:iterations` — число итераций Монте-Карло;
    * `:rng` — источник случайности; тот же seed даёт тот же результат;
    * `:dead_cards` — карты, которые точно не выйдут;
    * `:threshold` — граница точного перебора для `:auto`;
    * `:outs` — считать ли ауты (по умолчанию да);
    * `:parallel` — считать ли Монте-Карло чанками по ядрам (по умолчанию да).
  """
  @spec equity([hand_spec()], [Card.t()], Variant.t(), keyword()) :: EquityResult.t()
  def equity(hands, board, variant, opts \\ []) do
    context = HandRank.context(variant)
    dead_cards = Keyword.get(opts, :dead_cards, [])
    deck = available_cards(hands, board, dead_cards, context)
    missing_board = context.variant.board_size() - length(board)
    unknown = Enum.count(hands, fn {_id, hole} -> hole == :unknown end)
    draw = missing_board + unknown * context.variant.hole_cards_count()

    mode = resolve_mode(Keyword.get(opts, :mode, :auto), unknown, length(deck), draw, opts)

    {tally, simulations} =
      case mode do
        :exact -> run_exact(hands, board, deck, missing_board, context)
        :monte_carlo -> run_monte_carlo(hands, board, deck, missing_board, unknown, context, opts)
      end

    outs =
      if Keyword.get(opts, :outs, true) do
        Outs.compute(hands, board, context, dead_cards)
      else
        %{}
      end

    %EquityResult{
      players: players(hands, tally, simulations, outs),
      simulations: simulations,
      mode: mode
    }
  end

  defp resolve_mode(:exact, unknown, _size, _draw, _opts) when unknown > 0 do
    raise ArgumentError,
          "точный перебор требует известных карт у всех игроков: " <>
            "неизвестные руки считаются только Монте-Карло"
  end

  defp resolve_mode(:exact, _unknown, _size, _draw, _opts), do: :exact
  defp resolve_mode(:monte_carlo, _unknown, _size, _draw, _opts), do: :monte_carlo
  defp resolve_mode(:auto, unknown, _size, _draw, _opts) when unknown > 0, do: :monte_carlo

  defp resolve_mode(:auto, _unknown, size, draw, opts) do
    threshold = Keyword.get(opts, :threshold, @exact_threshold)

    if Combinatorics.count(size, draw) <= threshold, do: :exact, else: :monte_carlo
  end

  defp run_exact(hands, board, deck, missing_board, context) do
    runout = fn drawn, {tally, count} ->
      {score(hands, drawn ++ board, context, tally), count + 1}
    end

    Combinatorics.reduce_combinations(deck, missing_board, {empty_tally(hands), 0}, runout)
  end

  defp run_monte_carlo(hands, board, deck, missing_board, unknown, context, opts) do
    iterations = Keyword.get(opts, :iterations, @default_iterations)
    rng = Keyword.get_lazy(opts, :rng, &Rng.default/0)
    hole_size = context.variant.hole_cards_count()

    plan = %{
      hands: hands,
      board: board,
      deck: List.to_tuple(deck),
      deck_size: length(deck),
      missing_board: missing_board,
      hole_size: hole_size,
      draw: missing_board + unknown * hole_size,
      context: context
    }

    chunks =
      if Keyword.get(opts, :parallel, true) and iterations >= 2_000 do
        System.schedulers_online()
      else
        1
      end

    sizes = split_evenly(iterations, chunks)
    {rngs, _rng} = Rng.split(rng, length(sizes))

    tally =
      sizes
      |> Enum.zip(rngs)
      |> Task.async_stream(fn {size, chunk_rng} -> simulate(plan, size, chunk_rng) end,
        ordered: true,
        timeout: :infinity
      )
      |> Enum.reduce(empty_tally(hands), fn {:ok, chunk}, acc -> merge(acc, chunk) end)

    {tally, iterations}
  end

  defp simulate(plan, iterations, rng) do
    1..iterations//1
    |> Enum.reduce({empty_tally(plan.hands), rng}, fn _index, {tally, rng} ->
      {drawn, rng} = sample(plan.deck, plan.deck_size, plan.draw, rng)
      {board_cards, hole_cards} = Enum.split(drawn, plan.missing_board)
      {dealt, []} = deal_unknown(plan.hands, hole_cards, plan.hole_size)
      {score(dealt, board_cards ++ plan.board, plan.context, tally), rng}
    end)
    |> elem(0)
  end

  # Частичный Fisher–Yates: тасуется ровно столько карт, сколько нужно.
  defp sample(deck, size, count, rng) do
    {_deck, taken, rng} =
      Enum.reduce(0..(count - 1)//1, {deck, [], rng}, fn index, {deck, taken, rng} ->
        {offset, rng} = Rng.uniform_below(rng, size - index)
        swap = index + offset
        card = elem(deck, swap)
        deck = deck |> put_elem(swap, elem(deck, index)) |> put_elem(index, card)
        {deck, [card | taken], rng}
      end)

    {taken, rng}
  end

  defp deal_unknown(hands, cards, hole_size) do
    Enum.map_reduce(hands, cards, fn
      {id, :unknown}, cards ->
        {hole, rest} = Enum.split(cards, hole_size)
        {{id, hole}, rest}

      known, cards ->
        {known, cards}
    end)
  end

  defp score(hands, board, context, tally) do
    {_best, winners} =
      Enum.reduce(hands, {-1, []}, fn {id, hole}, {best, winners} ->
        score = HandRank.best_score(context.variant.candidate_hands(hole, board), context)

        cond do
          score > best -> {score, [id]}
          score == best -> {best, [id | winners]}
          true -> {best, winners}
        end
      end)

    splitting = length(winners)
    Enum.reduce(winners, tally, &credit(&2, &1, splitting))
  end

  defp credit(tally, id, 1) do
    Map.update!(tally, id, fn {wins, ties, equity} -> {wins + 1, ties, equity + 1} end)
  end

  defp credit(tally, id, splitting) do
    Map.update!(tally, id, fn {wins, ties, equity} ->
      {wins, ties + 1, equity + 1 / splitting}
    end)
  end

  defp available_cards(hands, board, dead_cards, context) do
    seen =
      hands
      |> Enum.flat_map(fn
        {_id, :unknown} -> []
        {_id, hole} -> hole
      end)
      |> Enum.concat(board)
      |> Enum.concat(dead_cards)
      |> CardSet.from_list()

    Enum.reject(context.variant.deck(), &CardSet.member?(seen, &1))
  end

  defp empty_tally(hands), do: Map.new(hands, fn {id, _hole} -> {id, {0, 0, 0.0}} end)

  defp merge(left, right) do
    Map.merge(left, right, fn _id, {wins, ties, equity}, {other_wins, other_ties, other_equity} ->
      {wins + other_wins, ties + other_ties, equity + other_equity}
    end)
  end

  defp players(hands, tally, simulations, outs) do
    Enum.map(hands, fn {id, _hole} ->
      {wins, ties, equity} = Map.fetch!(tally, id)

      %{
        id: id,
        win: wins / simulations,
        tie: ties / simulations,
        equity: equity / simulations,
        outs: Map.get(outs, id, [])
      }
    end)
  end

  defp split_evenly(total, chunks) do
    base = div(total, chunks)
    rest = rem(total, chunks)

    1..chunks//1
    |> Enum.map(fn index -> if index <= rest, do: base + 1, else: base end)
    |> Enum.reject(&(&1 == 0))
  end
end
