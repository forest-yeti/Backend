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

  @behaviour BlockPoker.Engine.Discipline

  alias BlockPoker.Engine.{
    BombPot,
    Card,
    Deck,
    HandInsight,
    Equity,
    HandRank,
    HandSetup,
    Outs,
    Reveal,
    Rng,
    RunItTwice,
    Showdown,
    Straddle,
    Variant
  }

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
          acted?: boolean()
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
          board_2: [Card.t()] | nil,
          bomb_pot: BombPot.t() | nil,
          run_it_twice_allowed?: boolean(),
          rit: RunItTwice.t() | nil,
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
    # Второй прогон борда. `nil` — обычная раздача, и весь код, написанный
    # до run it twice, работает с этим значением без единой правки.
    :board_2,
    # Открытый вопрос «играем дважды?». `nil` — не спрашивали.
    :rit,
    # Взнос бомб-пота, если раздача им оказалась. `nil` — обычная раздача.
    :bomb_pot,
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
    runout?: false,
    # Разрешение приходит из режима через `HandSetup`: кэш читает шаблон,
    # турнир отвечает `false` всегда.
    run_it_twice_allowed?: false
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
  @impl true
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
           acted?: false
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
      # Страддл поднимает номинал круга: после ставки вслепую в 10 BB
      # минимальный рейз считается от неё, а не от блайнда.
      bet_unit: Straddle.bet_unit(setup, structure.bet_unit(setup)),
      run_it_twice_allowed?: setup.run_it_twice_allowed,
      bomb_pot: setup.bomb_pot,
      rake_fun: Keyword.get(opts, :rake)
    }

    forced = structure.forced_bets(setup) ++ Straddle.forced_bets(setup)
    {hand, forced_events} = post_forced_bets(hand, forced)
    hand = %{hand | aggressor: Straddle.seat(setup)}
    {hand, entry_events} = post_entries(hand, setup)
    hand = deal_hole(hand)

    hand = %{hand | bet: max_committed(hand), min_raise: hand.bet_unit}
    {hand, opening_events} = open(hand, setup, structure)

    {hand,
     forced_events ++
       entry_events ++ [{:hole_dealt, hole_payload(hand)}] ++ opening_events}
  end

  # Чем раздача открывается. Обычная — префлопом: торговля начинается после
  # того, кто по структуре ставок говорит последним. Бомб-пот — сразу флопом:
  # заплатили все и поровну, торговаться до карт борда не о чем и некому.
  defp open(hand, %HandSetup{bomb_pot: nil} = setup, structure) do
    hand = %{hand | to_act: first_to_act(hand, structure.last_to_act_preflop(setup))}
    {hand, prompt(hand)}
  end

  defp open(hand, %HandSetup{}, _structure) do
    {hand, event} = deal_street(hand)
    hand = %{hand | to_act: first_to_act(hand)}

    # Взнос мог оказаться больше короткого стека: тогда говорить на флопе
    # уже некому и борд доводится до конца, как при обычном олл-ине.
    if hand.to_act == nil do
      {hand, events} = begin_runout(hand)
      {hand, [event | events]}
    else
      {hand, [event | prompt(hand)]}
    end
  end

  @doc "Легальные действия игрока — единственный источник правды для кнопок."
  @impl true
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
  @impl true
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
  @impl true
  @spec timeout(t()) :: {:ok, t(), [tuple()]} | {:error, atom()}
  def timeout(%__MODULE__{to_act: nil}), do: {:error, :no_action}

  def timeout(%__MODULE__{} = hand) do
    seat = hand.to_act
    free? = Map.fetch!(hand.players, seat).committed == hand.bet
    act(hand, seat, if(free?, do: :check, else: :fold), nil)
  end

  @doc """
  Кто на вскрытии открылся, а кто ушёл в мук (`Engine.Reveal`).

  До конца раздачи решения ещё нет — пустая карта.
  """
  @impl true
  @spec reveal_decision(t()) :: %{pos_integer() => :show | :muck}
  def reveal_decision(%__MODULE__{results: %{reveal: reveal}}), do: reveal
  def reveal_decision(%__MODULE__{}), do: %{}

  @doc "Кому принадлежит место в этой раздаче."
  @spec player_id(t(), pos_integer()) :: term() | nil
  def player_id(%__MODULE__{} = hand, seat) do
    case Map.get(hand.players, seat) do
      nil -> nil
      player -> player.id
    end
  end

  @doc """
  Карманные карты по местам — то, из чего собирается окно показа после
  раздачи. Живой раздаче эта функция не нужна и ею не вызывается.
  """
  @impl true
  @spec hole_cards(t()) :: %{pos_integer() => [Card.t()]}
  def hole_cards(%__MODULE__{} = hand) do
    hand.players
    |> Enum.filter(fn {_seat, player} -> player.hole != [] end)
    |> Map.new(fn {seat, player} -> {seat, player.hole} end)
  end

  @doc "Текущая лучшая комбинация игрока — то, что клиент подписывает под столом."
  @spec combination(t(), pos_integer()) :: HandRank.t() | nil
  def combination(%__MODULE__{} = hand, seat) do
    case Map.get(hand.players, seat) do
      %{hole: hole} when hole != [] -> Showdown.evaluate(hole, hand.board, hand.context)
      _other -> nil
    end
  end

  @doc """
  Разбор своей руки для окна-калькулятора: что играет и какие есть доезды.

  Отдельно от `combination/2` сознательно: подпись под столом и окно
  подсказок живут разными жизнями, и первое не должно меняться каждый раз,
  когда во втором добавилась строчка.
  """
  @impl true
  @spec insight(t(), pos_integer()) :: HandInsight.t() | nil
  def insight(%__MODULE__{} = hand, seat) do
    case Map.get(hand.players, seat) do
      %{hole: hole} when hole != [] -> HandInsight.analyze(hole, hand.board, hand.context)
      _other -> nil
    end
  end

  # --- Engine.Discipline ----------------------------------------------------
  #
  # Холдем и был той дисциплиной, под которую писалась оболочка, поэтому
  # реализация behaviour здесь — не слой поверх правил, а подпись под тем,
  # что модуль и так умел. Ни одна функция ниже не решает ничего нового.

  @impl true
  def id, do: :holdem

  @impl true
  def min_players, do: 2

  @impl true
  def max_players, do: 10

  @impl true
  def to_act(%__MODULE__{to_act: seat}), do: seat

  @impl true
  def seq(%__MODULE__{seq: seq}), do: seq

  @impl true
  def players(%__MODULE__{players: players}) do
    Map.new(players, fn {seat, player} ->
      {seat, %{id: player.id, stack: player.stack, total: player.total}}
    end)
  end

  @impl true
  def results(%__MODULE__{results: results}), do: results

  @doc """
  Чего раздача ждёт: хода, ответа про два прогона, следующей улицы доводки
  или ничего — она кончилась.

  Порядок проверок — это порядок приоритетов стола: доигранную раздачу не
  спрашивают об ответах, а открытый вопрос останавливает доводку.
  """
  @impl true
  def progress(%__MODULE__{} = hand) do
    cond do
      finished?(hand) -> :finished
      offering_run_it_twice?(hand) -> :offering
      hand.runout? -> :running_out
      true -> :acting
    end
  end

  @impl true
  def offer_view(%__MODULE__{rit: rit} = hand) do
    if offering_run_it_twice?(hand), do: %{seats: rit.seats}
  end

  @impl true
  def stats_new(%__MODULE__{} = hand), do: BlockPoker.Engine.HandStats.new(hand)

  @impl true
  def rabbit_runout(%__MODULE__{} = hand), do: BlockPoker.Engine.Rabbit.runout(hand)

  @doc """
  Публичная часть раздачи в снапшоте: борд, банк, чей ход.

  Карманных карт здесь нет и быть не может — они уходят только владельцу
  места. Карты помечены `{:cards, _}`: превращать целое число в
  `%{rank, suit}` обязан транспорт, а не раздача.
  """
  @impl true
  def public_view(%__MODULE__{} = hand) do
    %{
      street: hand.street,
      # Взнос идущей раздачи, если она бомбовая: по нему клиент подписывает
      # банк, а не пересчитывает его сам.
      bomb_pot: hand.bomb_pot,
      board: {:cards, hand.board},
      # Второй прогон борда; `nil` — обычная раздача.
      board_2: hand.board_2 && {:cards, hand.board_2},
      pot: hand.pot,
      bet: hand.bet,
      to_act: hand.to_act,
      action_seq: hand.seq,
      seats:
        Map.new(hand.players, fn {seat, player} ->
          {seat, %{committed: player.committed, total: player.total, status: player.status}}
        end)
    }
  end

  @doc """
  Личная часть снапшота: свои карты, своя комбинация, свои легальные
  действия. `nil` — этого места в раздаче нет.
  """
  @impl true
  def private_view(%__MODULE__{} = hand, seat) do
    case Map.get(hand.players, seat) do
      nil ->
        nil

      player ->
        %{
          hole_cards: {:cards, player.hole},
          combination: combination_view(combination(hand, seat)),
          # Окно-калькулятор: что играет и какие есть доезды. Приходит и
          # снапшотом, чтобы открытое окно не ждало отдельного запроса.
          insight: insight(hand, seat),
          in_hand: player.status != :folded,
          legal_actions: legal_actions(hand, seat)
        }
    end
  end

  defp combination_view(nil), do: nil
  defp combination_view(rank), do: %{category: rank.category, cards: {:cards, rank.cards}}

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
  #
  # Порядок событий здесь — правило, а не удобство отрисовки: карты
  # вскрываются **раньше** вопроса о двух прогонах, чтобы игрок решал,
  # видя расклад и проценты.
  defp begin_runout(hand) do
    hand = %{hand | to_act: nil}
    showdown = {:all_in_showdown, showdown_payload(hand)}

    case offer_seats(hand) do
      nil ->
        {%{hand | runout?: true}, [showdown]}

      seats ->
        hand = %{hand | rit: RunItTwice.offer(seats)}
        {hand, [showdown, {:run_it_twice_offer, %{seats: seats}}]}
    end
  end

  # Кого спрашивать про два прогона — и спрашивать ли вообще.
  #
  # Условия перечислены здесь целиком и намеренно в одном месте: разнесённые
  # по оболочке, они разъезжаются с движком при первом же изменении правил.
  defp offer_seats(%__MODULE__{run_it_twice_allowed?: false}), do: nil

  defp offer_seats(hand) do
    seats = hand |> contenders() |> Enum.map(& &1.seat)
    missing = hand |> board_plan() |> Enum.reduce(0, fn {_street, count}, acc -> acc + count end)

    # Карт должно хватить на оба борда: варианты с четырьмя карманными
    # картами появятся строкой в реестре, а не правкой этого условия.
    if length(seats) == 2 and missing > 0 and length(hand.deck) >= missing * 2 do
      seats
    else
      nil
    end
  end

  @doc """
  Ответ игрока на предложение сыграть дважды.

  Право отвечать — правило игры, а не транспорта: проверяется здесь, а не
  в канале.
  """
  @spec answer_run_it_twice(t(), pos_integer(), boolean()) ::
          {:ok, t(), [tuple()]} | {:error, atom()}
  def answer_run_it_twice(%__MODULE__{} = hand, seat, accept?) do
    with {:ok, rit} <- RunItTwice.answer(hand.rit, seat, accept?) do
      {hand, events} = settle_offer(%{hand | rit: rit})
      {:ok, hand, events}
    end
  end

  @doc """
  Закрыть предложение снаружи: время вышло. Неотвеченное — отказ.
  """
  @spec close_run_it_twice(t()) :: {:ok, t(), [tuple()]} | {:error, atom()}
  def close_run_it_twice(%__MODULE__{rit: nil}), do: {:error, :run_it_twice_not_offered}

  def close_run_it_twice(%__MODULE__{} = hand) do
    {hand, events} = settle_offer(%{hand | rit: RunItTwice.close(hand.rit)})
    {:ok, hand, events}
  end

  @doc "Ждёт ли раздача ответа про два прогона."
  @spec offering_run_it_twice?(t()) :: boolean()
  def offering_run_it_twice?(%__MODULE__{rit: rit}), do: RunItTwice.offered?(rit)

  # Пока исход не определён — ничего не происходит и стол ждёт. Как только
  # определён, доводка начинается обычным порядком, и единственный след
  # согласия — второй борд.
  defp settle_offer(hand) do
    if RunItTwice.offered?(hand.rit) do
      {hand, []}
    else
      accepted? = RunItTwice.accepted?(hand.rit)
      hand = %{hand | runout?: true, board_2: if(accepted?, do: hand.board, else: nil)}

      {hand, [{:run_it_twice_decided, %{accepted: accepted?, answers: hand.rit.answers}}]}
    end
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
  #
  # Считается **по каждому прогону отдельно**: борды разные, и один общий
  # процент не соответствует ни одному из них.
  defp equity_payload(hand) do
    known = hand |> contenders() |> Enum.map(&{&1.seat, &1.hole})

    if length(known) < 2 do
      []
    else
      boards = boards(hand)

      boards
      |> Enum.with_index()
      |> Enum.map(fn {board, index} ->
        %{run: index + 1, equity: equity_for(hand, known, board, dead_for(boards, board))}
      end)
    end
  end

  # Борд у прогонов свой, а колода — общая, и это правило счёта, а не деталь
  # отображения. Карта, легшая на тёрн первого прогона, физически ушла из
  # колоды: во втором прогоне она выйти не может, и показывать её как аут —
  # прямая ложь игроку и завышенный процент.
  #
  # Пример, ради которого этот расчёт существует: четыре аута на флопе, один
  # из них пришёл на тёрн первого прогона — на втором борде аутов остаётся
  # три, а не четыре.
  #
  # Мёртвые карты прогона — то, что лежит на **чужом** борде и отсутствует
  # на своём. Общий префикс до олл-ина сюда не входит: он уже учтён бордом.
  defp dead_for(boards, board), do: Enum.flat_map(boards, &(&1 -- board))

  defp equity_for(hand, known, board, dead_cards) do
    result =
      Equity.equity(known, board, hand.variant,
        iterations: 20_000,
        outs: false,
        dead_cards: dead_cards
      )

    outs = Outs.compute(known, board, hand.context, dead_cards)

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

  defp out_payload(out) do
    %{rank: out.rank, count: out.count, cards: Enum.map(out.cards, &Card.to_map/1)}
  end

  defp contenders(hand), do: hand |> seated() |> Enum.filter(&(&1.status != :folded))

  defp deal_street(hand) do
    street = @streets |> Enum.drop_while(&(&1 != hand.street)) |> Enum.at(1)
    count = Map.fetch!(@board_cards, street)
    {cards, deck} = Enum.split(hand.deck, count)

    # Прогоны идут улица в улицу, а не «первый до ривера, потом второй»:
    # порядок откусывания от колоды — часть правил, потому что он решает,
    # какому борду какая карта досталась, и обязан быть воспроизводим по seed.
    {board_2, deck} = deal_second(hand.board_2, deck, count)

    hand = %{
      hand
      | street: street,
        board: hand.board ++ cards,
        board_2: board_2,
        deck: deck,
        bet: 0,
        min_raise: hand.bet_unit,
        aggressor: nil,
        players:
          Map.new(hand.players, fn {seat, player} ->
            {seat, %{player | committed: 0, acted?: player.status != :active}}
          end)
    }

    {hand,
     {:street_dealt,
      %{
        street: street,
        board: board_payload(hand),
        board_2: second_board_payload(hand),
        pot: hand.pot
      }}}
  end

  defp deal_second(nil, deck, _count), do: {nil, deck}

  defp deal_second(board_2, deck, count) do
    {cards, deck} = Enum.split(deck, count)
    {board_2 ++ cards, deck}
  end

  defp finish(hand) do
    results = payout(hand)

    # Кто открывается, а кто мучует, решается здесь: дальше `runout?`
    # обнуляется, и признак «торговли больше не было» уже не восстановить.
    reveal = Reveal.decide(hand, results)

    hand = %{
      hand
      | street: :complete,
        to_act: nil,
        runout?: false,
        # Решение о показе едет вместе с результатом: комната по нему
        # заводит окно добровольного показа и не пересчитывает его сама.
        results: Map.put(results, :reveal, reveal),
        # Банк уехал в стеки: держать его ещё и в `pot` значило бы удвоить
        # фишки в инварианте. Итоговый размер живёт в `results.pots`.
        pot: 0,
        players:
          Map.new(hand.players, fn {seat, player} ->
            {seat, %{player | stack: player.stack + Map.get(results.payouts, seat, 0)}}
          end)
    }

    {hand, [{:hand_finished, finish_payload(hand, results, reveal)}]}
  end

  # --- банк и вскрытие ------------------------------------------------------

  defp payout(hand) do
    contenders = Enum.filter(seated(hand), &(&1.status != :folded))

    case contenders do
      [only] ->
        # Все сбросили: вскрытия нет, победитель не обязан показывать карты.
        {amount, rake} = take_rake(hand, hand.pot, 1)

        %{
          runs: [
            %{
              run: 1,
              board: board_payload(hand),
              pots: [%{amount: amount, winners: [only.seat]}],
              placements: []
            }
          ],
          payouts: %{only.seat => amount},
          rake: rake,
          showdown?: false
        }

      _many ->
        showdown(hand, contenders)
    end
  end

  # Вскрытие разбито на две несвязанные вещи, и это разделение — не украшение.
  #
  # **Слои банка от борда не зависят.** Сколько слоёв, какого размера и кто
  # на них претендует — определяют вложения игроков; карты решают только, кто
  # из претендентов слой забрал. Поэтому слои и рейк считаются **один раз**,
  # а ранжировка — по разу на прогон (§6 задачи 5).
  #
  # Отсюда же и защита от главной денежной ошибки run it twice: прогнать
  # `payout/1` дважды означало бы снять рейк дважды. В такой структуре это
  # невыразимо — `take_rake/3` живёт в `pot_layers/2` и вызывается один раз
  # независимо от числа прогонов.
  defp showdown(hand, contenders) do
    {layers, refunds} = pot_layers(hand, contenders)

    rake =
      hand.pot - Enum.sum(Enum.map(layers, & &1.amount)) - Enum.sum(Map.values(refunds))

    boards = boards(hand)
    entries = Enum.map(contenders, &{&1.seat, &1.hole})

    {runs, payouts} =
      boards
      |> Enum.with_index()
      |> Enum.map_reduce(%{}, fn {board, index}, payouts ->
        placements = Showdown.showdown(entries, board, hand.context)
        place_of = Map.new(placements, &{&1.player_id, &1.place})
        pots = resolve_layers(layers, place_of, index, length(boards))

        run = %{
          run: index + 1,
          board: Enum.map(board, &Card.to_map/1),
          pots: pots,
          placements: placements
        }

        {run, merge_chips(payouts, distribute(pots, hand.button_seat, hand.order))}
      end)

    %{
      runs: runs,
      payouts: merge_chips(payouts, refunds),
      rake: rake,
      showdown?: true
    }
  end

  # Борды раздачи в порядке прогонов. Обычная раздача — один; принятый
  # run it twice — два, с общим префиксом до олл-ина.
  defp boards(%__MODULE__{board_2: nil, board: board}), do: [board]
  defp boards(%__MODULE__{board_2: board_2, board: board}), do: [board, board_2]

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
  defp pot_layers(hand, contenders) do
    dead = hand |> seated() |> Enum.reduce(0, &(&1.dead + &2))

    # Потолок банка — вторая по величине ставка за раздачу: выше неё ставку
    # никто не покрыл, и эти фишки в банк не входят.
    cap = matched_cap(hand)

    refunds =
      hand
      |> seated()
      |> Enum.filter(&(&1.total > cap))
      |> Map.new(&{&1.seat, &1.total - cap})

    levels =
      contenders
      |> Enum.map(&min(&1.total, cap))
      |> Enum.filter(&(&1 > 0))
      |> Enum.uniq()
      |> Enum.sort()

    {layers, _prev} =
      levels
      |> Enum.with_index()
      |> Enum.map_reduce(0, fn {level, index}, prev ->
        contributed =
          Enum.reduce(seated(hand), 0, fn player, acc ->
            total = min(player.total, cap)
            acc + min(total, level) - min(total, prev)
          end)

        # Мёртвые деньги целиком идут в основной банк: своего слоя у них нет.
        amount = contributed + if(index == 0, do: dead, else: 0)

        eligible =
          contenders |> Enum.filter(&(min(&1.total, cap) >= level)) |> Enum.map(& &1.seat)

        {amount, _rake} = take_rake(hand, amount, length(eligible))

        {%{amount: amount, eligible: eligible}, level}
      end)

    layers = if levels == [], do: [dead_only_layer(hand, contenders, dead)], else: layers

    {Enum.reject(layers, &(&1.amount == 0)), refunds}
  end

  # Кто забрал каждый слой на этом борде — и сколько от слоя причитается
  # этому прогону.
  #
  # Нечётная фишка достаётся **первому** прогону: правило детерминированное,
  # не зависит ни от позиции, ни от порядка мест, и объясняется игроку одной
  # фразой. Делить её случайно нельзя — в системе не должно появляться и
  # исчезать ни одной фишки (§11 CLAUDE.md).
  defp resolve_layers(layers, place_of, index, runs) do
    layers
    |> Enum.map(fn layer ->
      best = layer.eligible |> Enum.map(&Map.fetch!(place_of, &1)) |> Enum.min(fn -> nil end)
      winners = Enum.filter(layer.eligible, &(Map.fetch!(place_of, &1) == best))

      # `eligible` уходит наружу вместе с банком: по нему баунти-турнир
      # находит **тот** банк, в котором у выбывшего кончились фишки, —
      # а он не обязательно самый большой (§6.4 задачи 7). Номера мест
      # публичны, скрывать здесь нечего.
      %{
        amount: share(layer.amount, index, runs),
        winners: winners,
        eligible: layer.eligible
      }
    end)
    |> Enum.reject(&(&1.amount == 0 or &1.winners == []))
  end

  defp share(amount, 0, runs), do: div(amount, runs) + rem(amount, runs)
  defp share(amount, _index, runs), do: div(amount, runs)

  defp merge_chips(left, right), do: Map.merge(left, right, fn _seat, a, b -> a + b end)

  # Вырожденный случай: ставок не было вовсе, а мёртвые деньги в банке есть.
  # Разыгрывают их те, кто дошёл до вскрытия.
  defp dead_only_layer(hand, contenders, dead) do
    seats = Enum.map(contenders, & &1.seat)
    {amount, _rake} = take_rake(hand, dead, max(length(seats), 1))
    %{amount: amount, eligible: seats}
  end

  defp matched_cap(hand) do
    case hand |> seated() |> Enum.map(& &1.total) |> Enum.sort(:desc) do
      [] -> 0
      [only] -> only
      [_highest, second | _rest] -> second
    end
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
    amount = min(due(bet, player), player.stack)

    hand = commit(hand, player, amount)
    hand = settle_forced_bet(hand, bet, committed, amount)

    {hand,
     [{:posted, %{seat: bet.seat, kind: to_string(bet.kind), amount: amount, pot: hand.pot}}]}
  end

  # Сумма к постановке. Обычная вынужденная ставка вносится поверх уже
  # вложенного, `top_up?` — до указанного итога: страддливший блайнд платит
  # разницу, а не страддл сверх блайнда.
  defp due(%{top_up?: true, amount: amount}, player), do: max(amount - player.committed, 0)
  defp due(%{amount: amount}, _player), do: amount

  defp settle_forced_bet(hand, %{live?: true, seat: seat} = bet, _committed, _amount) do
    # `option?` — сохраняет ли поставивший право голоса, когда до него дойдёт
    # очередь. Блайнд и анте кнопки сохраняют, страддл — нет: порядок хода он
    # не меняет и переспрашивать уравнявших ему не за чем.
    put_player(hand, %{Map.fetch!(hand.players, seat) | acted?: not option?(bet)})
  end

  defp settle_forced_bet(hand, %{seat: seat}, committed, amount) do
    hand
    |> put_player(%{Map.fetch!(hand.players, seat) | committed: committed})
    |> mark_dead(seat, amount)
  end

  defp option?(bet), do: Map.get(bet, :option?, true)

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
    Enum.count(seated(hand), &(&1.status == :active)) <= 1
  end

  defp single_contender?(hand) do
    Enum.count(seated(hand), &(&1.status != :folded)) == 1
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

  defp seated(hand), do: Map.values(hand.players)

  # Деньги, которые лежат в банке, но ставкой игрока не являются. Отдельный
  # счётчик нужен разбору банка: слои сайд-потов строятся по ставкам, а
  # мёртвые деньги своего слоя не образуют.
  defp mark_dead(hand, seat, amount) do
    player = Map.fetch!(hand.players, seat)
    put_player(hand, %{player | total: player.total - amount, dead: player.dead + amount})
  end

  defp put_player(hand, player), do: %{hand | players: Map.put(hand.players, player.seat, player)}

  defp max_committed(hand),
    do: hand |> seated() |> Enum.map(& &1.committed) |> Enum.max(fn -> 0 end)

  defp hole_payload(hand) do
    Map.new(hand.players, fn {seat, player} -> {seat, Enum.map(player.hole, &Card.to_map/1)} end)
  end

  defp board_payload(hand), do: Enum.map(hand.board, &Card.to_map/1)

  defp second_board_payload(%__MODULE__{board_2: nil}), do: nil
  defp second_board_payload(%__MODULE__{board_2: board_2}), do: Enum.map(board_2, &Card.to_map/1)

  defp finish_payload(hand, results, reveal) do
    %{
      runs: Enum.map(results.runs, &run_payload/1),
      payouts: results.payouts,
      rake: Map.get(results, :rake, 0),
      showdown: results.showdown?,
      shown: shown_cards(hand, reveal),
      # Кто дошёл до вскрытия, но карт не открыл. Стол должен видеть, что
      # рука ушла в мук, а не просто «ничего не показали».
      mucked: mucked_seats(hand, reveal)
    }
  end

  # Прогон наружу: борд, банки и номер. Ранжировка (`placements`) остаётся
  # внутри движка — она нужна расчёту и статистике, а в сообщении несёт
  # структуру `HandRank`, которую JSON не кодирует. Отправка такого payload
  # роняла канал, и вскрытие до клиента не доезжало вовсе.
  defp run_payload(run) do
    %{run: run.run, board: run.board, pots: run.pots}
  end

  # Что реально уходит в сокет. Кого открывать, решает `Engine.Reveal` по
  # правилам вскрытия; добровольный показ здесь не участвует — он живёт в
  # окне после раздачи и приезжает отдельным событием.
  defp shown_cards(hand, reveal) do
    hand
    |> seated()
    |> Enum.filter(&(&1.hole != [] and Map.get(reveal, &1.seat) == :show))
    |> Enum.sort_by(& &1.seat)
    |> Enum.map(fn player ->
      rank = Showdown.evaluate(player.hole, hand.board, hand.context)

      %{
        seat: player.seat,
        cards: Enum.map(player.hole, &Card.to_map/1),
        category: rank && rank.category,
        # Те пять карт, из которых комбинация и собралась. Клиент по ним
        # подсвечивает борд: «выиграл вот этим», а не «выиграл почему-то».
        # Считаются по сыгранному борду — при двух прогонах по первому.
        combo: rank && Enum.map(rank.cards, &Card.to_map/1)
      }
    end)
  end

  # Мук — только про тех, кто до вскрытия дошёл. Сбросивший руку раньше
  # ничего не мучует: он и не был обязан показывать.
  defp mucked_seats(hand, reveal) do
    hand
    |> seated()
    |> Enum.filter(&(&1.status != :folded and Map.get(reveal, &1.seat) == :muck))
    |> Enum.map(& &1.seat)
    |> Enum.sort()
  end
end
