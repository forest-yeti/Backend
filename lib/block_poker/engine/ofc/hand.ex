defmodule BlockPoker.Engine.Ofc.Hand do
  @moduledoc """
  Раздача открытого китайского покера (ананас) целиком.

  Ни борда, ни торговли, ни банка: игроки по очереди выкладывают карты в три
  бокса, а по концу раздачи рассчитываются очками — каждый с каждым отдельно.
  Из-за этого дисциплина и не выражается вариантом покера: `Variant` отвечает
  на вопрос «из чего собирается пятёрка», а здесь другой вопрос — «что вообще
  происходит в раздаче».

  Колода тасуется **один раз** в начале раздачи, сдачи откусывают от её
  головы. Трое игроков разбирают 3 × 17 = 51 карту, поэтому дотасовки не
  бывает; четвёртому игроку колоды уже не хватает, и дисциплина его не
  сажает (`max_players/0`).

  Очерёдность собирается **расписанием** — списком ходов на всю раздачу, а не
  пересчитывается на каждом шаге. Так фантазия ложится в общий порядок без
  исключений: игрок в фантазии занимает один ход в самом начале и в круги
  дальше не входит.

  Модуль чистый: ни процессов, ни таймеров, ни `Repo`.
  """

  @behaviour BlockPoker.Engine.Discipline

  alias BlockPoker.Engine.{Card, Deck, HandRank, HandSetup}
  alias BlockPoker.Engine.Ofc.{Autoplace, Board, Royalties, Score, Settlement}

  # Первая сдача — пять карт и все пять в боксы. Дальше четыре круга по три
  # карты: две в боксы, одна в сброс.
  @first_deal %{deal: 5, place: 5, discard: 0}
  @round_deal %{deal: 3, place: 2, discard: 1}
  # Фантазия: вся рука закрыто и одним ходом.
  @fantasy_deal %{deal: 14, place: 13, discard: 1}
  @rounds 4

  # Фантазия зарабатывается парой дам и выше: 10 — внутренний ранг дамы.
  @fantasy_pair 10

  @typedoc "Место в раздаче: раскладка, рука на руках и сбросы."
  @type player :: %{
          id: term(),
          stack: non_neg_integer(),
          total: non_neg_integer(),
          board: Board.t(),
          hand: [Card.t()],
          discards: [Card.t()],
          fantasy?: boolean()
        }

  @type t :: %__MODULE__{}

  @enforce_keys [:context, :deck, :rng, :players, :point_value]
  defstruct [
    :context,
    :deck,
    :rng,
    :players,
    :point_value,
    :results,
    # Что сдано текущему ходящему и сколько от него ждут. Запись одна:
    # ход в раздаче в каждый момент ровно один.
    :turn,
    :to_act,
    schedule: [],
    seq: 0
  ]

  # --- Engine.Discipline ----------------------------------------------------

  @impl true
  def id, do: :ofc_pineapple

  @impl true
  def min_players, do: 2

  @doc """
  Троих ананас держит впритык: 3 × 17 = 51 карта из 52. Четвёртому колоды не
  хватает, и это правило дисциплины, а не настройка стола.
  """
  @impl true
  def max_players, do: 3

  @impl true
  def start(%HandSetup{} = setup, rng, _opts) do
    {deck, rng} = Deck.shuffle(Deck.new(setup.variant), rng)

    players =
      Map.new(setup.players, fn player ->
        {player.seat,
         %{
           id: player.id,
           stack: player.stack,
           total: player.stack,
           board: Board.new(),
           hand: [],
           discards: [],
           fantasy?: Map.get(player, :fantasy, false)
         }}
      end)

    hand = %__MODULE__{
      context: HandRank.context(setup.variant),
      deck: deck,
      rng: rng,
      players: players,
      point_value: setup.point_value,
      schedule: schedule(setup, players)
    }

    open_turn(hand, [{:hand_dealt, %{seats: Enum.sort(Map.keys(players))}}])
  end

  @impl true
  def act(%__MODULE__{to_act: nil}, _seat, _action, _seq), do: {:error, :hand_finished}

  def act(%__MODULE__{to_act: seat} = hand, seat, {:place, placements, discard}, action_seq)
      when action_seq == nil or is_integer(action_seq) do
    if action_seq == nil or action_seq == hand.seq do
      place(hand, seat, placements, discard)
    else
      {:error, :stale_action}
    end
  end

  def act(%__MODULE__{}, _seat, {:place, _placements, _discard}, _seq),
    do: {:error, :not_your_turn}

  def act(%__MODULE__{}, _seat, _action, _seq), do: {:error, :illegal_action}

  @doc """
  Ход за отвалившегося. Фолд здесь невозможен: мёртвая рука — это минус шесть
  каждому сопернику и испорченная раздача остальным, поэтому тайм-аут
  **раскладывает карты**, а не сдаёт их (`Ofc.Autoplace`).
  """
  @impl true
  def timeout(%__MODULE__{to_act: nil}), do: {:error, :no_action}

  def timeout(%__MODULE__{to_act: seat, turn: turn} = hand) do
    {placements, discard} =
      Autoplace.choose(turn.board, turn.cards, turn.discard, hand.context)

    act(hand, seat, {:place, placements, discard}, nil)
  end

  @doc """
  Легального выбора «что сделать» в раскладке нет: игрок решает не что, а
  куда положить. Наружу уходит форма хода — сколько карт выложить, сколько
  сбросить и сколько места осталось в каждом боксе.
  """
  @impl true
  def legal_actions(%__MODULE__{to_act: seat, turn: turn}, seat) when turn != nil do
    %{place: turn.place, discard: turn.discard, rows: free_rows(turn.board)}
  end

  def legal_actions(%__MODULE__{}, _seat), do: %{}

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
  def progress(%__MODULE__{to_act: nil}), do: :finished
  def progress(%__MODULE__{}), do: :acting

  @impl true
  def results(%__MODULE__{results: results}), do: results

  @doc """
  Публичная часть: чужие боксы и признак фантазии. Ни рук, ни сбросов —
  соперник не вправе видеть их ни в какой момент, а карты фантазии закрыты
  до вскрытия.
  """
  @impl true
  def public_view(%__MODULE__{} = hand) do
    %{
      to_act: hand.to_act,
      action_seq: hand.seq,
      seats:
        Map.new(hand.players, fn {seat, player} ->
          {seat,
           %{
             rows: rows_view(player.board),
             placed: Board.size(player.board),
             discarded: length(player.discards),
             fantasy: player.fantasy?,
             # Роспись собранных боксов. Считает её всё равно сервер, а без
             # неё клиенту пришлось бы завести вторую копию правил варианта.
             combinations: categories(hand, player)
           }}
        end),
      showdown: hand.results && hand.results.showdown
    }
  end

  @doc """
  Личное: своя рука, свои сбросы и своя форма хода. Сбросы видит только их
  владелец — соперникам не уходит ни карта, ни при вскрытии.
  """
  @impl true
  def private_view(%__MODULE__{} = hand, seat) do
    case Map.get(hand.players, seat) do
      nil ->
        nil

      player ->
        %{
          deal: {:cards, player.hand},
          discards: {:cards, player.discards},
          rows: rows_view(player.board),
          royalties: royalties(hand, player),
          combinations: categories(hand, player),
          in_hand: true,
          legal_actions: legal_actions(hand, seat)
        }
    end
  end

  # --- ход раздачи ----------------------------------------------------------

  # Расписание ходов на всю раздачу. Фантазия занимает один ход в самом
  # начале: игрок выкладывает всю руку сразу и в круги дальше не входит, а
  # соперники играют обычную раздачу, не видя его карт до вскрытия.
  defp schedule(%HandSetup{} = setup, players) do
    order = setup |> HandSetup.order_from_button() |> Enum.map(& &1.seat)
    {fantasy, normal} = Enum.split_with(order, &players[&1].fantasy?)

    Enum.map(fantasy, &{&1, @fantasy_deal}) ++
      Enum.flat_map(0..@rounds, fn
        0 -> Enum.map(normal, &{&1, @first_deal})
        _round -> Enum.map(normal, &{&1, @round_deal})
      end)
  end

  # Следующий ход: сдаём карты тому, чья очередь, и объявляем форму хода.
  # Сдача происходит здесь, а не в начале раздачи, чтобы карты не лежали в
  # состоянии раньше, чем игрок вправе их увидеть.
  defp open_turn(%__MODULE__{schedule: []} = hand, events), do: finish(hand, events)

  defp open_turn(%__MODULE__{schedule: [{seat, form} | rest]} = hand, events) do
    {cards, deck} = Enum.split(hand.deck, form.deal)
    player = %{hand.players[seat] | hand: cards}

    hand = %{
      hand
      | deck: deck,
        schedule: rest,
        players: Map.put(hand.players, seat, player),
        to_act: seat,
        turn: %{cards: cards, place: form.place, discard: form.discard, board: player.board}
    }

    event = {:deal, %{seat: seat, cards: cards, place: form.place, discard: form.discard}}

    {hand, events ++ [event]}
  end

  defp place(%__MODULE__{turn: turn} = hand, seat, placements, discard) do
    with :ok <- validate_shape(turn, placements, discard),
         :ok <- validate_cards(turn.cards, placements, discard),
         {:ok, board} <- Board.place(turn.board, placements) do
      player = hand.players[seat]

      player = %{
        player
        | board: board,
          hand: [],
          discards: player.discards ++ List.wrap(discard)
      }

      hand = %{
        hand
        | players: Map.put(hand.players, seat, player),
          seq: hand.seq + 1,
          to_act: nil,
          turn: nil
      }

      # Сброс в событие не входит: соперник не вправе его видеть. Ряды
      # уходят наружу нормализованными — как их поняла дисциплина, а не
      # как их назвал клиент.
      event =
        {:placed,
         %{
           seat: seat,
           placements:
             Enum.map(placements, fn {card, row} ->
               {:ok, row} = Board.fetch_row(row)
               %{card: card, row: row}
             end)
         }}

      {hand, events} = open_turn(hand, [event])
      {:ok, hand, events}
    end
  end

  defp validate_shape(turn, placements, discard) do
    if is_list(placements) and length(placements) == turn.place and
         length(List.wrap(discard)) == turn.discard do
      :ok
    else
      {:error, :invalid_placement}
    end
  end

  # Выложить можно только то, что сдали, и каждую карту ровно один раз.
  defp validate_cards(dealt, placements, discard) do
    used = Enum.map(placements, fn {card, _row} -> card end) ++ List.wrap(discard)

    if Enum.sort(used) == Enum.sort(dealt), do: :ok, else: {:error, :invalid_placement}
  end

  # --- расчёт ---------------------------------------------------------------

  defp finish(%__MODULE__{} = hand, events) do
    boards = Map.new(hand.players, fn {seat, player} -> {seat, player.board} end)
    stacks = Map.new(hand.players, fn {seat, player} -> {seat, player.stack} end)

    scores = Score.score(boards, hand.context)
    %{transfers: transfers, deltas: deltas} = Settlement.settle(scores, stacks, hand.point_value)

    players =
      Map.new(hand.players, fn {seat, player} ->
        {seat, %{player | stack: player.stack + deltas[seat]}}
      end)

    showdown = showdown(hand, scores, deltas)

    results = %{
      showdown: showdown,
      scores: Map.new(scores, fn {seat, entry} -> {seat, entry.total} end),
      transfers: transfers,
      deltas: deltas,
      # Кому фантазия достаётся в следующей раздаче. Решает дисциплина, а
      # хранит место (`Seat`): фантазия по определению живёт между раздачами.
      fantasy: Map.new(hand.players, fn {seat, player} -> {seat, fantasy?(hand, player)} end)
    }

    {%{hand | players: players, to_act: nil, turn: nil, results: results},
     events ++ [{:showdown, showdown}]}
  end

  defp showdown(hand, scores, deltas) do
    seats =
      Map.new(hand.players, fn {seat, player} ->
        {seat,
         %{
           rows: rows_view(player.board),
           combinations: categories(hand, player),
           foul: scores[seat].foul?,
           royalties: scores[seat].royalties.rows,
           points: scores[seat].total,
           delta: deltas[seat]
         }}
      end)

    %{seats: seats}
  end

  # Фантазия зарабатывается парой дам и выше сверху; удерживается сетом
  # сверху либо каре и выше снизу. Мёртвая рука не даёт ни того, ни другого.
  defp fantasy?(hand, player) do
    cond do
      Board.foul?(player.board, hand.context) -> false
      player.fantasy? -> hold_fantasy?(hand, player)
      true -> earn_fantasy?(hand, player)
    end
  end

  defp earn_fantasy?(hand, player) do
    case Board.rank(player.board, :top, hand.context) do
      %HandRank{category: :pair, cards: [card | _rest]} -> Card.rank(card) >= @fantasy_pair
      %HandRank{category: :three_of_a_kind} -> true
      _other -> false
    end
  end

  defp hold_fantasy?(hand, player) do
    top = Board.rank(player.board, :top, hand.context)
    bottom = Board.rank(player.board, :bottom, hand.context)

    top.category == :three_of_a_kind or
      bottom.category in [:four_of_a_kind, :straight_flush]
  end

  defp royalties(hand, player) do
    if Board.complete?(player.board) do
      Royalties.for_board(player.board, hand.context).rows
    else
      Map.new(Board.rows(), &{&1, 0})
    end
  end

  # Роспись каждого бокса или `nil`, пока он не собран: неполную руку не
  # оценивают, и придумывать ей категорию нельзя.
  defp categories(hand, player) do
    Map.new(Board.rows(), fn row ->
      rank = Board.rank(player.board, row, hand.context)
      {row, rank && rank.category}
    end)
  end

  defp rows_view(board) do
    Map.new(Board.rows(), &{&1, {:cards, Board.cards(board, &1)}})
  end

  defp free_rows(board) do
    Map.new(Board.rows(), &{&1, Board.free(board, &1)})
  end
end
