defmodule BlockPoker.Engine.Hand do
  @moduledoc """
  Ход раздачи: блайнды, карманные карты, улицы, торговля, вскрытие.

  Модуль чистый — ни процессов, ни кошельков, ни таймеров. Он принимает
  `HandSetup`, отдаёт новое состояние и список событий; кто их разошлёт и
  кто спишет фишки, решает слой стола. Благодаря этому вся арифметика денег
  проверяется обычным тестом, а инвариант «фишки не возникают и не
  исчезают» держится на `total_chips/1`.

  Ставки хранятся двумя числами: `committed` — вложенное на текущей улице
  (по нему считается `to_call`), `total` — за всю раздачу (по нему строятся
  сайд-поты). Одно из другого не выводится: улица обнуляет первое и не
  трогает второе.
  """

  alias BlockPoker.Engine.{Card, Deck, HandRank, HandSetup, Rng, Showdown, Variant}

  @type street :: :preflop | :flop | :turn | :river | :complete
  @type status :: :active | :folded | :all_in
  @type action ::
          :fold | :check | :call | {:bet, pos_integer()} | {:raise, pos_integer()} | :all_in

  @type player :: %{
          seat: pos_integer(),
          id: term(),
          stack: non_neg_integer(),
          hole: [Card.t()],
          committed: non_neg_integer(),
          total: non_neg_integer(),
          status: status(),
          acted?: boolean(),
          show?: boolean()
        }

  @type t :: %__MODULE__{
          variant: Variant.t(),
          context: HandRank.Context.t(),
          deck: [Card.t()],
          rng: Rng.t(),
          players: %{pos_integer() => player()},
          order: [pos_integer()],
          button_seat: pos_integer(),
          small_blind: pos_integer(),
          big_blind: pos_integer(),
          street: street(),
          board: [Card.t()],
          pot: non_neg_integer(),
          bet: non_neg_integer(),
          min_raise: pos_integer(),
          to_act: pos_integer() | nil,
          aggressor: pos_integer() | nil,
          seq: non_neg_integer(),
          rake_fun: (non_neg_integer(), pos_integer() -> non_neg_integer()) | nil,
          results: map() | nil
        }

  @enforce_keys [:variant, :context, :deck, :rng, :players, :order, :button_seat]
  defstruct [
    :variant,
    :context,
    :deck,
    :rng,
    :players,
    :order,
    :button_seat,
    :to_act,
    :aggressor,
    :rake_fun,
    :results,
    small_blind: 0,
    big_blind: 0,
    street: :preflop,
    board: [],
    pot: 0,
    bet: 0,
    min_raise: 0,
    seq: 0
  ]

  @streets [:preflop, :flop, :turn, :river]
  @board_cards %{flop: 3, turn: 1, river: 1}

  @doc """
  Начало раздачи: анте, блайнды, карманные карты и первый ход.

  Возвращает состояние и события в порядке возникновения — клиент рисует
  их как есть, ничего не досчитывая.
  """
  @spec start(HandSetup.t(), Rng.t(), keyword()) :: {t(), [tuple()]}
  def start(%HandSetup{} = setup, rng, opts \\ []) do
    {deck, rng} = setup.variant |> Deck.new() |> Deck.shuffle(rng)
    order = setup |> HandSetup.order_from_button() |> Enum.map(& &1.seat)

    players =
      Map.new(setup.players, fn player ->
        {player.seat,
         %{
           seat: player.seat,
           id: player.id,
           stack: player.stack,
           hole: [],
           committed: 0,
           total: 0,
           status: :active,
           acted?: false,
           show?: false
         }}
      end)

    hand = %__MODULE__{
      variant: setup.variant,
      context: HandRank.context(setup.variant),
      deck: deck,
      rng: rng,
      players: players,
      order: order,
      button_seat: setup.button_seat,
      small_blind: setup.small_blind,
      big_blind: setup.big_blind,
      rake_fun: Keyword.get(opts, :rake)
    }

    {hand, ante_events} = post_antes(hand, setup)
    {hand, blind_events} = post_blinds(hand)
    hand = deal_hole(hand)

    hand = %{hand | bet: max_committed(hand), min_raise: setup.big_blind}
    hand = %{hand | to_act: first_to_act(hand)}

    {hand, ante_events ++ blind_events ++ [{:hole_dealt, hole_payload(hand)}] ++ prompt(hand)}
  end

  @doc "Легальные действия игрока — единственный источник правды для кнопок."
  @spec legal_actions(t(), pos_integer()) :: map()
  def legal_actions(%__MODULE__{} = hand, seat) do
    player = Map.get(hand.players, seat)

    if player == nil or hand.to_act != seat do
      %{}
    else
      to_call = min(hand.bet - player.committed, player.stack)

      # Рейз возможен, только если за ним есть чем ответить: короткий олл-ин
      # ставку не поднимает и торговлю не переоткрывает.
      raise_min = min(hand.bet + hand.min_raise, player.committed + player.stack)
      raise_max = player.committed + player.stack

      %{
        fold: true,
        check: to_call == 0,
        call: if(to_call > 0, do: to_call, else: nil),
        raise: if(raise_max > hand.bet, do: %{min: raise_min, max: raise_max}, else: nil),
        all_in: player.stack
      }
    end
  end

  @doc """
  Действие игрока. `seq` защищает от даблкликов и лагов: клиент присылает
  тот счётчик, который видел, устаревший отвергается.
  """
  @spec act(t(), pos_integer(), action(), non_neg_integer() | nil) ::
          {:ok, t(), [tuple()]} | {:error, atom()}
  def act(%__MODULE__{street: :complete}, _seat, _action, _seq), do: {:error, :hand_finished}

  def act(%__MODULE__{} = hand, seat, action, seq) do
    cond do
      hand.to_act != seat -> {:error, :not_your_turn}
      seq != nil and seq != hand.seq -> {:error, :stale_action}
      true -> apply_action(hand, Map.fetch!(hand.players, seat), action)
    end
  end

  @doc "Время на ход вышло: чек, если бесплатно, иначе фолд."
  @spec timeout(t()) :: {:ok, t(), [tuple()]} | {:error, atom()}
  def timeout(%__MODULE__{to_act: nil}), do: {:error, :no_action}

  def timeout(%__MODULE__{} = hand) do
    seat = hand.to_act
    free? = Map.fetch!(hand.players, seat).committed == hand.bet
    act(hand, seat, if(free?, do: :check, else: :fold), nil)
  end

  @doc """
  Просьба показать карты. Сбросивший может открыться по желанию, дошедший
  до вскрытия — тоже: правила не обязывают показывать всё, но и не мешают.
  """
  @spec show_cards(t(), pos_integer()) :: {:ok, t(), [tuple()]} | {:error, atom()}
  def show_cards(%__MODULE__{} = hand, seat) do
    case Map.get(hand.players, seat) do
      nil ->
        {:error, :not_seated}

      %{hole: []} ->
        {:error, :no_cards}

      player ->
        hand = put_player(hand, %{player | show?: true})
        {:ok, hand, [{:cards_shown, %{seat: seat, cards: Enum.map(player.hole, &Card.to_map/1)}}]}
    end
  end

  @doc "Текущая лучшая комбинация игрока — то, что клиент подписывает под столом."
  @spec combination(t(), pos_integer()) :: HandRank.t() | nil
  def combination(%__MODULE__{} = hand, seat) do
    case Map.get(hand.players, seat) do
      %{hole: hole} when hole != [] -> Showdown.evaluate(hole, hand.board, hand.context)
      _other -> nil
    end
  end

  @doc "Сумма фишек в раздаче: стеки плюс банк. Инвариант денег."
  @spec total_chips(t()) :: non_neg_integer()
  def total_chips(%__MODULE__{} = hand) do
    Enum.reduce(hand.players, hand.pot, fn {_seat, player}, acc -> acc + player.stack end)
  end

  @spec finished?(t()) :: boolean()
  def finished?(%__MODULE__{street: :complete}), do: true
  def finished?(%__MODULE__{}), do: false

  # --- действия -------------------------------------------------------------

  defp apply_action(hand, player, :fold) do
    hand
    |> put_player(%{player | status: :folded, acted?: true})
    |> after_action(player.seat, %{action: "fold", amount: 0})
  end

  defp apply_action(hand, player, :check) do
    if player.committed == hand.bet do
      hand
      |> put_player(%{player | acted?: true})
      |> after_action(player.seat, %{action: "check", amount: 0})
    else
      {:error, :illegal_action}
    end
  end

  defp apply_action(hand, player, :call) do
    amount = min(hand.bet - player.committed, player.stack)

    if amount == 0 do
      {:error, :illegal_action}
    else
      hand
      |> commit(player, amount)
      |> after_action(player.seat, %{action: "call", amount: amount})
    end
  end

  defp apply_action(hand, player, :all_in) do
    raise_to = player.committed + player.stack
    apply_raise(hand, player, raise_to, forced?: true)
  end

  defp apply_action(hand, player, {bet_or_raise, to}) when bet_or_raise in [:bet, :raise] do
    apply_raise(hand, player, to, forced?: false)
  end

  defp apply_action(_hand, _player, _action), do: {:error, :illegal_action}

  defp apply_raise(hand, player, to, opts) do
    max_to = player.committed + player.stack
    legal_min = min(hand.bet + hand.min_raise, max_to)

    cond do
      to > max_to -> {:error, :illegal_action}
      to <= hand.bet and to < max_to -> {:error, :illegal_action}
      not opts[:forced?] and to < legal_min -> {:error, :illegal_action}
      true -> do_raise(hand, player, to)
    end
  end

  defp do_raise(hand, player, to) do
    amount = to - player.committed
    raise_by = to - hand.bet
    hand = commit(hand, player, amount)

    # Полноценный рейз переоткрывает торговлю: остальные снова должны ответить.
    full? = raise_by >= hand.min_raise

    hand = %{
      hand
      | bet: max(hand.bet, to),
        min_raise: if(full?, do: raise_by, else: hand.min_raise),
        aggressor: if(full?, do: player.seat, else: hand.aggressor)
    }

    hand = if full?, do: reopen(hand, player.seat), else: hand
    label = if hand.players[player.seat].stack == 0, do: "all_in", else: "raise"
    after_action(hand, player.seat, %{action: label, amount: amount, to: to})
  end

  defp reopen(hand, except_seat) do
    players =
      Map.new(hand.players, fn {seat, player} ->
        acted? = seat == except_seat or player.status != :active
        {seat, %{player | acted?: acted?}}
      end)

    %{hand | players: players}
  end

  defp commit(hand, player, amount) do
    updated = %{
      player
      | stack: player.stack - amount,
        committed: player.committed + amount,
        total: player.total + amount,
        acted?: true,
        status: if(player.stack - amount == 0, do: :all_in, else: player.status)
    }

    %{put_player(hand, updated) | pot: hand.pot + amount}
  end

  defp after_action(hand, seat, payload) do
    hand = %{hand | seq: hand.seq + 1}
    player = Map.fetch!(hand.players, seat)

    event =
      {:action_taken,
       Map.merge(payload, %{
         seat: seat,
         stack: player.stack,
         pot: hand.pot,
         action_seq: hand.seq
       })}

    {hand, events} = advance(hand)
    {:ok, hand, [event | events]}
  end

  # --- продвижение раздачи --------------------------------------------------

  defp advance(hand) do
    cond do
      single_contender?(hand) -> finish(hand)
      street_open?(hand) -> {%{hand | to_act: next_to_act(hand)}, prompt(hand_next(hand))}
      hand.street == :river -> finish(hand)
      no_more_betting?(hand) -> run_out(hand)
      true -> next_street(hand)
    end
  end

  # `prompt/1` должен видеть уже сдвинутый ход, поэтому считаем его от нового
  # состояния, а не от старого.
  defp hand_next(hand), do: %{hand | to_act: next_to_act(hand)}

  defp next_street(hand) do
    {hand, event} = deal_street(hand)
    hand = %{hand | to_act: first_to_act(hand)}

    if hand.to_act == nil do
      {hand, [event]}
    else
      {hand, [event | prompt(hand)]}
    end
  end

  # Ставить больше некому — доводим борд до конца и вскрываемся.
  defp run_out(hand) do
    {hand, events} =
      Enum.reduce(remaining_streets(hand), {hand, []}, fn _street, {acc, events} ->
        {acc, event} = deal_street(acc)
        {acc, events ++ [event]}
      end)

    {hand, finish_events} = finish(hand)
    {hand, events ++ finish_events}
  end

  defp remaining_streets(hand) do
    @streets |> Enum.drop_while(&(&1 != hand.street)) |> tl()
  end

  defp deal_street(hand) do
    street = @streets |> Enum.drop_while(&(&1 != hand.street)) |> Enum.at(1)
    count = Map.fetch!(@board_cards, street)
    {cards, deck} = Enum.split(hand.deck, count)

    hand = %{
      hand
      | street: street,
        board: hand.board ++ cards,
        deck: deck,
        bet: 0,
        min_raise: hand.big_blind,
        aggressor: nil,
        players:
          Map.new(hand.players, fn {seat, player} ->
            {seat, %{player | committed: 0, acted?: player.status != :active}}
          end)
    }

    {hand, {:street_dealt, %{street: street, board: board_payload(hand), pot: hand.pot}}}
  end

  defp finish(hand) do
    results = payout(hand)

    hand = %{
      hand
      | street: :complete,
        to_act: nil,
        results: results,
        # Банк уехал в стеки: держать его ещё и в `pot` значило бы удвоить
        # фишки в инварианте. Итоговый размер живёт в `results.pots`.
        pot: 0,
        players:
          Map.new(hand.players, fn {seat, player} ->
            {seat, %{player | stack: player.stack + Map.get(results.payouts, seat, 0)}}
          end)
    }

    {hand, [{:hand_finished, finish_payload(hand, results)}]}
  end

  # --- банк и вскрытие ------------------------------------------------------

  defp payout(hand) do
    contenders = Enum.filter(players(hand), &(&1.status != :folded))

    case contenders do
      [only] ->
        # Все сбросили: вскрытия нет, победитель не обязан показывать карты.
        {amount, rake} = take_rake(hand, hand.pot, 1)

        %{
          pots: [%{amount: amount, winners: [only.seat]}],
          payouts: %{only.seat => amount},
          rake: rake,
          showdown?: false,
          placements: []
        }

      _many ->
        showdown(hand, contenders)
    end
  end

  defp showdown(hand, contenders) do
    entries = Enum.map(contenders, &{&1.seat, &1.hole})
    placements = Showdown.showdown(entries, hand.board, hand.context)
    place_of = Map.new(placements, &{&1.player_id, &1.place})

    {pots, payouts} = split_pots(hand, place_of)
    rake = hand.pot - Enum.sum(Enum.map(pots, & &1.amount))

    %{pots: pots, payouts: payouts, rake: rake, showdown?: true, placements: placements}
  end

  # Сайд-поты строятся по уровням вложенного за раздачу: каждый уровень
  # разыгрывают только те, кто дошёл до него своими фишками.
  defp split_pots(hand, place_of) do
    levels =
      hand
      |> players()
      |> Enum.map(& &1.total)
      |> Enum.filter(&(&1 > 0))
      |> Enum.uniq()
      |> Enum.sort()

    {pots, _prev} =
      Enum.map_reduce(levels, 0, fn level, prev ->
        amount =
          hand
          |> players()
          |> Enum.reduce(0, fn player, acc ->
            acc + min(player.total, level) - min(player.total, prev)
          end)

        eligible =
          hand
          |> players()
          |> Enum.filter(&(&1.total >= level and Map.has_key?(place_of, &1.seat)))
          |> Enum.map(& &1.seat)

        best = eligible |> Enum.map(&Map.fetch!(place_of, &1)) |> Enum.min(fn -> nil end)
        winners = Enum.filter(eligible, &(Map.fetch!(place_of, &1) == best))
        {amount, _rake} = take_rake(hand, amount, length(eligible))

        {%{amount: amount, winners: winners}, level}
      end)

    pots = Enum.reject(pots, &(&1.amount == 0))
    {pots, distribute(pots, hand.button_seat, hand.order)}
  end

  # Неделимый остаток достаётся ближайшему от кнопки по часовой стрелке —
  # так решают за живым столом, и так остаток не исчезает.
  defp distribute(pots, _button_seat, order) do
    Enum.reduce(pots, %{}, fn pot, acc ->
      count = length(pot.winners)
      share = div(pot.amount, count)
      odd = rem(pot.amount, count)
      sorted = Enum.sort_by(pot.winners, &Enum.find_index(order, fn seat -> seat == &1 end))

      sorted
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {seat, index}, acc ->
        extra = if index < odd, do: 1, else: 0
        Map.update(acc, seat, share + extra, &(&1 + share + extra))
      end)
    end)
  end

  # Рейк считает переданная функция: движку всё равно, кэш это с рейком или
  # турнир без него.
  defp take_rake(%{rake_fun: nil}, amount, _players), do: {amount, 0}

  defp take_rake(%{rake_fun: fun} = hand, amount, players) do
    rake = min(fun.(amount, players, saw_flop?: hand.board != []), amount)
    {amount - rake, rake}
  end

  # --- вспомогательное ------------------------------------------------------

  defp post_antes(hand, %HandSetup{ante: 0}), do: {hand, []}

  defp post_antes(hand, %HandSetup{ante: ante, ante_type: :per_player}) do
    Enum.reduce(hand.order, {hand, []}, fn seat, {acc, events} ->
      player = Map.fetch!(acc.players, seat)
      amount = min(ante, player.stack)
      acc = commit(acc, player, amount)
      {acc, events ++ [{:posted, %{seat: seat, kind: "ante", amount: amount, pot: acc.pot}}]}
    end)
  end

  defp post_antes(hand, %HandSetup{ante: ante}) do
    seat = blind_seat(hand, :big)
    player = Map.fetch!(hand.players, seat)
    amount = min(ante, player.stack)
    hand = commit(hand, player, amount)

    # Анте за стол вносит большой блайнд — в банк, но не в счёт своей ставки.
    hand = put_player(hand, %{Map.fetch!(hand.players, seat) | committed: 0})
    {hand, [{:posted, %{seat: seat, kind: "ante", amount: amount, pot: hand.pot}}]}
  end

  defp post_blinds(hand) do
    [{:small, hand.small_blind}, {:big, hand.big_blind}]
    |> Enum.reduce({hand, []}, fn {kind, blind}, {acc, events} ->
      seat = blind_seat(acc, kind)
      player = Map.fetch!(acc.players, seat)
      amount = min(blind, player.stack)
      acc = commit(acc, player, amount)

      # Блайнд — не «ход»: слово за игроком всё равно останется.
      acc = put_player(acc, %{Map.fetch!(acc.players, seat) | acted?: false})
      label = if kind == :small, do: "small_blind", else: "big_blind"
      {acc, events ++ [{:posted, %{seat: seat, kind: label, amount: amount, pot: acc.pot}}]}
    end)
  end

  # На хедз-апе кнопка — малый блайнд и ходит первой до флопа.
  defp blind_seat(hand, kind) do
    seats = hand.order

    if length(seats) == 2 do
      case kind do
        :small -> hand.button_seat
        :big -> Enum.find(seats, &(&1 != hand.button_seat))
      end
    else
      case kind do
        :small -> Enum.at(seats, 0)
        :big -> Enum.at(seats, 1)
      end
    end
  end

  defp deal_hole(hand) do
    count = hand.variant.hole_cards_count()

    {players, deck} =
      Enum.reduce(hand.order, {hand.players, hand.deck}, fn seat, {players, deck} ->
        {cards, rest} = Enum.split(deck, count)
        {Map.update!(players, seat, &%{&1 | hole: cards}), rest}
      end)

    %{hand | players: players, deck: deck}
  end

  defp first_to_act(%{street: :preflop} = hand) do
    big = blind_seat(hand, :big)
    after_seat(hand, big)
  end

  defp first_to_act(hand) do
    # После флопа первым говорит ближайший от кнопки по часовой стрелке.
    hand.order |> Enum.filter(&can_act?(hand, &1)) |> List.first()
  end

  defp next_to_act(hand), do: after_seat(hand, hand.to_act)

  defp after_seat(hand, seat) do
    index = Enum.find_index(hand.order, &(&1 == seat)) || 0
    count = length(hand.order)

    1..count
    |> Enum.map(fn offset -> Enum.at(hand.order, rem(index + offset, count)) end)
    |> Enum.find(&can_act?(hand, &1))
  end

  defp can_act?(hand, seat) do
    player = Map.fetch!(hand.players, seat)
    player.status == :active and not (player.acted? and player.committed == hand.bet)
  end

  defp street_open?(hand), do: next_to_act(hand) != nil

  defp no_more_betting?(hand) do
    Enum.count(players(hand), &(&1.status == :active)) <= 1
  end

  defp single_contender?(hand) do
    Enum.count(players(hand), &(&1.status != :folded)) == 1
  end

  defp prompt(%{to_act: nil}), do: []

  defp prompt(hand) do
    player = Map.fetch!(hand.players, hand.to_act)

    [
      {:action_prompt,
       %{
         seat: hand.to_act,
         action_seq: hand.seq,
         to_call: min(hand.bet - player.committed, player.stack),
         legal_actions: legal_actions(hand, hand.to_act)
       }}
    ]
  end

  defp players(hand), do: Map.values(hand.players)
  defp put_player(hand, player), do: %{hand | players: Map.put(hand.players, player.seat, player)}

  defp max_committed(hand),
    do: hand |> players() |> Enum.map(& &1.committed) |> Enum.max(fn -> 0 end)

  defp hole_payload(hand) do
    Map.new(hand.players, fn {seat, player} -> {seat, Enum.map(player.hole, &Card.to_map/1)} end)
  end

  defp board_payload(hand), do: Enum.map(hand.board, &Card.to_map/1)

  defp finish_payload(hand, results) do
    %{
      board: board_payload(hand),
      pots: results.pots,
      payouts: results.payouts,
      rake: Map.get(results, :rake, 0),
      showdown: results.showdown?,
      shown: shown_cards(hand, results)
    }
  end

  # Что реально уходит в сокет: на вскрытии карты показывают участники,
  # без вскрытия — только те, кто попросил открыться сам.
  defp shown_cards(hand, results) do
    hand
    |> players()
    |> Enum.filter(fn player ->
      player.hole != [] and (player.show? or (results.showdown? and player.status != :folded))
    end)
    |> Enum.sort_by(& &1.seat)
    |> Enum.map(fn player ->
      rank = Showdown.evaluate(player.hole, hand.board, hand.context)

      %{
        seat: player.seat,
        cards: Enum.map(player.hole, &Card.to_map/1),
        category: rank && rank.category
      }
    end)
  end
end
