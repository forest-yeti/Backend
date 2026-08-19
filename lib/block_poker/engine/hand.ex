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

  alias BlockPoker.Engine.{Card, Deck, Equity, HandRank, HandSetup, Outs, Rng, Showdown, Variant}

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
          dead: non_neg_integer(),
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
          bet_unit: non_neg_integer(),
          street: street(),
          board: [Card.t()],
          pot: non_neg_integer(),
          bet: non_neg_integer(),
          min_raise: pos_integer(),
          to_act: pos_integer() | nil,
          aggressor: pos_integer() | nil,
          seq: non_neg_integer(),
          runout?: boolean(),
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
    # Номинал структуры ставок: от него считаются минимальный бет и рейз.
    # Блайндов и анте раздача не знает — только эту величину.
    bet_unit: 0,
    street: :preflop,
    board: [],
    pot: 0,
    bet: 0,
    min_raise: 0,
    seq: 0,
    # Ставить больше некому: борд доводится до конца с паузами, чтобы игрок
    # увидел каждую улицу, а не мгновенный итог.
    runout?: false
  ]

  @streets [:preflop, :flop, :turn, :river]
  @board_cards %{flop: 3, turn: 1, river: 1}

  @doc """
  Начало раздачи: вынужденные ставки, карманные карты и первый ход.

  Что именно ставится до карт и кто говорит первым, знает структура ставок
  (`Engine.BettingStructure`), а не эта функция: блайнды и анте кнопки
  отличаются только ею.

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
           dead: 0,
           status: :active,
           acted?: false,
           show?: false
         }}
      end)

    structure = HandSetup.structure(setup)

    hand = %__MODULE__{
      variant: setup.variant,
      context: HandRank.context(setup.variant),
      deck: deck,
      rng: rng,
      players: players,
      order: order,
      button_seat: setup.button_seat,
      bet_unit: structure.bet_unit(setup),
      rake_fun: Keyword.get(opts, :rake)
    }

    {hand, forced_events} = post_forced_bets(hand, structure.forced_bets(setup))
    {hand, entry_events} = post_entries(hand, setup)
    hand = deal_hole(hand)

    hand = %{hand | bet: max_committed(hand), min_raise: hand.bet_unit}
    hand = %{hand | to_act: first_to_act(hand, structure.last_to_act_preflop(setup))}

    {hand,
     forced_events ++
       entry_events ++ [{:hole_dealt, hole_payload(hand)}] ++ prompt(hand)}
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

  @doc """
  Улицы, которых борду не хватает до конца, и число карт на каждой.

  Живёт здесь, а не у вызывающего: состав борда — правило варианта, и
  второй его копии в кодовой базе быть не должно.
  """
  @spec board_plan(t()) :: [{street(), pos_integer()}]
  def board_plan(%__MODULE__{board: board, variant: variant}) do
    dealt = length(board)
    target = variant.board_size()

    [:flop, :turn, :river]
    |> Enum.map_reduce(0, fn street, size ->
      count = Map.fetch!(@board_cards, street)
      {{street, size, count}, size + count}
    end)
    |> elem(0)
    |> Enum.filter(fn {_street, size, count} -> size >= dealt and size + count <= target end)
    |> Enum.map(fn {street, _size, count} -> {street, count} end)
  end

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
      no_more_betting?(hand) -> begin_runout(hand)
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

  # Ставить больше некому. Карты открываются сразу — дальше только случай,
  # и прятать их незачем; борд доводится по улице за шаг снаружи.
  defp begin_runout(hand) do
    hand = %{hand | runout?: true, to_act: nil}
    {hand, [{:all_in_showdown, showdown_payload(hand)}]}
  end

  @doc """
  Следующая улица при доводке борда. Вызывается снаружи по таймеру: пауза
  между улицами — часть игры, а не украшение.
  """
  @spec deal_next(t()) :: {:ok, t(), [tuple()]} | {:error, atom()}
  def deal_next(%__MODULE__{runout?: false}), do: {:error, :not_running_out}
  def deal_next(%__MODULE__{street: :complete}), do: {:error, :hand_finished}

  def deal_next(%__MODULE__{street: :river} = hand) do
    {hand, events} = finish(hand)
    {:ok, hand, events}
  end

  def deal_next(%__MODULE__{} = hand) do
    {hand, event} = deal_street(hand)

    # Эквити пересчитывается на каждой улице: после флопа расклад уже другой.
    {:ok, hand, [event, {:equity_update, equity_payload(hand)}]}
  end

  # Карты и шансы всех, кто дошёл до доводки. Ровно то, что показывает
  # современный рум: открытые руки, проценты и ауты догоняющего.
  defp showdown_payload(hand) do
    %{
      board: board_payload(hand),
      players:
        hand
        |> contenders()
        |> Enum.map(fn player ->
          %{seat: player.seat, cards: Enum.map(player.hole, &Card.to_map/1)}
        end),
      equity: equity_payload(hand)
    }
  end

  # Точный перебор дорог на пяти неизвестных картах, поэтому Монте-Карло
  # с умеренным числом итераций: полпроцента погрешности игроку незаметны,
  # а секунда ожидания — очень даже.
  defp equity_payload(hand) do
    known = hand |> contenders() |> Enum.map(&{&1.seat, &1.hole})

    if length(known) < 2 do
      []
    else
      result = Equity.equity(known, hand.board, hand.variant, iterations: 20_000, outs: false)
      outs = Outs.compute(known, hand.board, hand.context)

      Enum.map(result.players, fn player ->
        %{
          seat: player.id,
          win: player.win,
          tie: player.tie,
          equity: player.equity,
          outs: outs |> Map.get(player.id, []) |> Enum.map(&out_payload/1)
        }
      end)
    end
  end

  defp out_payload(out) do
    %{rank: out.rank, count: out.count, cards: Enum.map(out.cards, &Card.to_map/1)}
  end

  defp contenders(hand), do: hand |> players() |> Enum.filter(&(&1.status != :folded))

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
        min_raise: hand.bet_unit,
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
        runout?: false,
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

    {pots, payouts, refunded} = split_pots(hand, place_of)
    rake = hand.pot - Enum.sum(Enum.map(pots, & &1.amount)) - refunded

    %{pots: pots, payouts: payouts, rake: rake, showdown?: true, placements: placements}
  end

  # Сайд-поты строятся по уровням, которые **разыгрывают претенденты**:
  # только их вложения делят банк на слои. Всё остальное — деньги, которые
  # в банке лежат, но своего слоя не образуют:
  #
  #   * мёртвые (анте, мёртвый взнос за вход, ставки сбросивших) — они
  #     достаются победителю основного банка;
  #   * неотвеченная часть ставки — её не покрыл ни один претендент, банком
  #     она не является и возвращается тому, кто её поставил.
  #
  # Считать слои по вложениям **всех** игроков нельзя: сбросивший большой
  # блайнд с анте вкладывает больше лимперов, и наверху появлялся слой, на
  # который не претендует никто. Такой банк делился между пустым списком
  # победителей — то есть на ноль.
  defp split_pots(hand, place_of) do
    contenders = hand |> players() |> Enum.filter(&Map.has_key?(place_of, &1.seat))
    dead = hand |> players() |> Enum.reduce(0, &(&1.dead + &2))

    # Потолок банка — вторая по величине ставка за раздачу: выше неё ставку
    # никто не покрыл, и эти фишки в банк не входят.
    cap = matched_cap(hand)

    refunds =
      hand
      |> players()
      |> Enum.filter(&(&1.total > cap))
      |> Map.new(&{&1.seat, &1.total - cap})

    levels =
      contenders
      |> Enum.map(&min(&1.total, cap))
      |> Enum.filter(&(&1 > 0))
      |> Enum.uniq()
      |> Enum.sort()

    {pots, _prev} =
      levels
      |> Enum.with_index()
      |> Enum.map_reduce(0, fn {level, index}, prev ->
        contributed =
          Enum.reduce(players(hand), 0, fn player, acc ->
            total = min(player.total, cap)
            acc + min(total, level) - min(total, prev)
          end)

        # Мёртвые деньги целиком идут в основной банк: своего слоя у них нет.
        amount = contributed + if(index == 0, do: dead, else: 0)

        eligible =
          contenders |> Enum.filter(&(min(&1.total, cap) >= level)) |> Enum.map(& &1.seat)

        best = eligible |> Enum.map(&Map.fetch!(place_of, &1)) |> Enum.min(fn -> nil end)
        winners = Enum.filter(eligible, &(Map.fetch!(place_of, &1) == best))
        {amount, _rake} = take_rake(hand, amount, length(eligible))

        {%{amount: amount, winners: winners}, level}
      end)

    pots = if levels == [], do: [dead_only_pot(hand, contenders, dead)], else: pots
    pots = Enum.reject(pots, &(&1.amount == 0 or &1.winners == []))
    payouts = distribute(pots, hand.button_seat, hand.order)

    {pots, Map.merge(payouts, refunds, fn _seat, paid, refund -> paid + refund end),
     Enum.sum(Map.values(refunds))}
  end

  defp matched_cap(hand) do
    case hand |> players() |> Enum.map(& &1.total) |> Enum.sort(:desc) do
      [] -> 0
      [only] -> only
      [_highest, second | _rest] -> second
    end
  end

  # Вырожденный случай: ставок не было вовсе, а мёртвые деньги в банке есть.
  # Разыгрывают их те, кто дошёл до вскрытия.
  defp dead_only_pot(hand, contenders, dead) do
    seats = Enum.map(contenders, & &1.seat)
    {amount, _rake} = take_rake(hand, dead, max(length(seats), 1))
    %{amount: amount, winners: seats}
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

  # Вынужденные ставки: суммы приходят от структуры, урезание по стеку —
  # здесь, потому что только раздача знает, сколько у игрока осталось.
  #
  # Живая ставка становится ставкой круга, и слово за поставившим остаётся:
  # большой блайнд и анте кнопки отвечают на рейз, как все. Мёртвая уходит
  # в банк, ставкой не считается и права чека не даёт — поэтому вложенное
  # возвращается из `committed` в то, чем оно было до постановки.
  defp post_forced_bets(hand, bets) do
    Enum.reduce(bets, {hand, []}, fn bet, {acc, events} ->
      {acc, event} = post_forced_bet(acc, bet)
      {acc, events ++ event}
    end)
  end

  defp post_forced_bet(hand, %{amount: amount}) when amount <= 0, do: {hand, []}

  defp post_forced_bet(hand, bet) do
    player = Map.fetch!(hand.players, bet.seat)
    committed = player.committed
    amount = min(bet.amount, player.stack)

    hand = commit(hand, player, amount)
    hand = settle_forced_bet(hand, bet, committed, amount)

    {hand,
     [{:posted, %{seat: bet.seat, kind: to_string(bet.kind), amount: amount, pot: hand.pot}}]}
  end

  defp settle_forced_bet(hand, %{live?: true, seat: seat}, _committed, _amount) do
    put_player(hand, %{Map.fetch!(hand.players, seat) | acted?: false})
  end

  defp settle_forced_bet(hand, %{seat: seat}, committed, amount) do
    hand
    |> put_player(%{Map.fetch!(hand.players, seat) | committed: committed})
    |> mark_dead(seat, amount)
  end

  # Взнос за вход вне очереди: игрок, не дожидавшийся своего большого
  # блайнда, платит столько же, сколько круг стоил бы сидящему.
  #
  # Живая часть взноса — ставка наравне с блайндом, мёртвая уходит в банк
  # и права чека не даёт. Живая при этом не может превысить текущую ставку
  # круга: взнос — это плата за вход, а не рейз, и остальным отвечать на
  # него нечем. Всё, что сверх, становится мёртвым.
  defp post_entries(hand, setup) do
    setup.players
    |> Enum.filter(&(entry_amount(&1) > 0))
    |> Enum.sort_by(& &1.seat)
    |> Enum.reduce({hand, []}, fn entry, {acc, events} ->
      player = Map.fetch!(acc.players, entry.seat)

      # Ставка круга берётся из уже поставленных блайндов: `hand.bet`
      # выставляется позже, по итогам всех обязательных взносов.
      live = min(Map.get(entry, :post, 0), max(max_committed(acc) - player.committed, 0))
      dead = entry_amount(entry) - live

      {acc, live_events} = post_live(acc, entry.seat, live)
      {acc, dead_events} = post_dead(acc, entry.seat, dead)

      {acc, events ++ live_events ++ dead_events}
    end)
  end

  defp entry_amount(entry), do: Map.get(entry, :post, 0) + Map.get(entry, :dead_post, 0)

  defp post_live(hand, _seat, 0), do: {hand, []}

  defp post_live(hand, seat, amount) do
    player = Map.fetch!(hand.players, seat)
    amount = min(amount, player.stack)
    hand = commit(hand, player, amount)

    # Взнос — не «ход»: слово за игроком на его очереди останется.
    hand = put_player(hand, %{Map.fetch!(hand.players, seat) | acted?: false})
    {hand, [{:posted, %{seat: seat, kind: "post", amount: amount, pot: hand.pot}}]}
  end

  defp post_dead(hand, _seat, 0), do: {hand, []}

  defp post_dead(hand, seat, amount) do
    player = Map.fetch!(hand.players, seat)
    committed = player.committed
    amount = min(amount, player.stack)
    hand = commit(hand, player, amount)

    # Мёртвая часть в ставку игрока не идёт: она уже в банке. Ставка
    # возвращается к тому, что было **до** неё, а не к нулю: живая часть
    # взноса могла быть внесена тем же игроком мгновением раньше.
    hand =
      put_player(hand, %{Map.fetch!(hand.players, seat) | committed: committed, acted?: false})

    {hand, [{:posted, %{seat: seat, kind: "dead_post", amount: amount, pot: hand.pot}}]}
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

  # Префлоп: торговля начинается после того, кто говорит последним, — кого
  # именно, решает структура ставок.
  defp first_to_act(hand, last), do: after_seat(hand, last)

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

  # Деньги, которые лежат в банке, но ставкой игрока не являются. Отдельный
  # счётчик нужен разбору банка: слои сайд-потов строятся по ставкам, а
  # мёртвые деньги своего слоя не образуют.
  defp mark_dead(hand, seat, amount) do
    player = Map.fetch!(hand.players, seat)
    put_player(hand, %{player | total: player.total - amount, dead: player.dead + amount})
  end

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
