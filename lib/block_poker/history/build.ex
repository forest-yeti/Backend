defmodule BlockPoker.History.Build do
  @moduledoc """
  Превращение отчёта о раздаче в строки таблиц.

  Модуль **чистый**: ни процессов, ни `Repo`, ни времени. Всё, что он
  делает, — перекладывает уже посчитанное ядром в форму строк, считает
  позиции (`History.Position`) и умножает готовые доли эквити на слои
  банка. Новой математики здесь нет и быть не должно: расчёт эквити
  второй раз — прямая ошибка реализации (§11 задачи 6).

  Живёт вне процесса стола (`History.Writer`), потому что даже дешёвый
  обход событий не имеет права выполняться там, где тикают таймеры хода.

  Дисциплина выбирает форму: холдем собирается в `hands` / `hand_players` /
  `hand_actions`, китайский покер — в `ofc_hands` / `ofc_hand_players`.
  Общего у них ровно один потребитель — дневной агрегат.
  """

  alias BlockPoker.Engine.{Card, Hand, Ofc, Stats}
  alias BlockPoker.History.{PlayerStatsDaily, Position, Report}

  @typedoc """
  Готовая к записи раздача: строка раздачи, строки участников, строки
  действий и прибавки к дневному агрегату.
  """
  @type rows :: %{
          kind: :holdem | :ofc,
          hand: map(),
          players: [map()],
          actions: [map()],
          stats: [map()]
        }

  @doc "Собрать строки по отчёту. Дисциплина определяется типом раздачи."
  @spec rows(Report.t()) :: rows()
  def rows(%Report{hand: %Hand{}} = report), do: holdem(report)
  def rows(%Report{hand: %Ofc.Hand{}} = report), do: ofc(report)

  # --- холдем ---------------------------------------------------------------

  defp holdem(%Report{hand: hand} = report) do
    results = hand.results || %{payouts: %{}, rake: 0, runs: [], showdown?: false}
    layers = pot_layers(results)
    equity = equity_shares(report)
    positions = hand.players |> Map.keys() |> Position.for_seats(report.button_seat)

    players =
      hand.players
      |> Enum.sort_by(fn {seat, _player} -> seat end)
      |> Enum.map(fn {seat, player} ->
        holdem_player(report, hand, results, player, positions[seat], layers, equity)
      end)

    %{
      kind: :holdem,
      hand: %{
        id: report.hand_id,
        room_id: report.room_id,
        game_mode: report.game_mode,
        setting_id: report.setting_id,
        tournament_id: report.tournament_id,
        level_number: report.level_number,
        hand_number: report.hand_number,
        variant: to_string(hand.variant.id()),
        button_seat: report.button_seat,
        bet_unit: report.bet_unit,
        small_blind: report.small_blind,
        big_blind: report.big_blind,
        ante: report.ante,
        board: Enum.map(hand.board, &Card.to_map/1),
        board_2: hand.board_2 && Enum.map(hand.board_2, &Card.to_map/1),
        bomb_pot: report.bomb_pot,
        pot: total_pot(layers, results),
        rake: Map.get(results, :rake, 0),
        pots: pots_payload(results),
        started_at: report.started_at,
        ended_at: report.ended_at
      },
      players: players,
      actions: actions(report, hand),
      stats: stats_rows(report, players)
    }
  end

  defp holdem_player(report, hand, results, player, position, layers, equity) do
    won = Map.get(results.payouts, player.seat, 0)

    %{
      hand_id: report.hand_id,
      user_id: player.id,
      seat: player.seat,
      position: position,
      # Стек до вынужденных ставок: в стеке раздачи уже лежит выплата,
      # а вложенное из него ушло.
      starting_stack: player.stack - won + player.total,
      hole_cards: Enum.map(player.hole, &Card.to_map/1),
      card_visibility: visibility(results, player),
      invested: player.total,
      won: won,
      net: won - player.total,
      ev_amount: ev_amount(layers, equity, player.seat),
      status: status(results, player),
      rank: rank(hand, results, player)
    }
  end

  # Что игроку разрешено показывать наружу. Источник — решение
  # `Engine.Reveal`, уже принятое в раздаче: «дошёл ли до вскрытия» тем же
  # ответом не является. Добровольный показ приходит позже, вторым
  # апдейтом по закрытию окна показа (§4 задачи 6).
  defp visibility(results, player) do
    case results |> Map.get(:reveal, %{}) |> Map.get(player.seat) do
      :show -> :showdown
      _other -> :hidden
    end
  end

  defp status(results, player) do
    cond do
      player.status == :folded -> :folded
      not Map.get(results, :showdown?, false) -> :won_uncontested
      player.status == :all_in -> :all_in
      true -> :showdown
    end
  end

  # Комбинация на вскрытии — из ранжировки первого прогона. Второй прогон
  # даёт другую руку тому же игроку, и «одна комбинация раздачи» для run it
  # twice не определена: реплей показывает оба борда сам.
  defp rank(_hand, %{showdown?: false}, _player), do: nil

  defp rank(_hand, results, player) do
    results
    |> Map.get(:runs, [])
    |> List.first(%{})
    |> Map.get(:placements, [])
    |> placements_high()
    |> Enum.find(&(&1.player_id == player.seat))
    |> case do
      nil -> nil
      %{rank: rank} -> %{category: to_string(rank.category), cards: cards_of(rank)}
    end
  end

  # Hi-Lo даёт две ранжировки; в историю пока едет старшая — низкая рука
  # это отдельная колонка, которой в схеме нет.
  defp placements_high(%{high: high}), do: high
  defp placements_high(placements) when is_list(placements), do: placements
  defp placements_high(_other), do: []

  defp cards_of(%{cards: cards}), do: Enum.map(cards, &Card.to_map/1)
  defp cards_of(_rank), do: []

  # Банк раздачи до рейка: слои плюс снятый с них рейк. Складывать
  # вложенное нельзя — неотвеченная часть ставки в банк не входит и
  # возвращается владельцу, а в слоях её уже нет.
  defp total_pot(layers, results) do
    Enum.reduce(layers, 0, &(&1.amount + &2)) + Map.get(results, :rake, 0)
  end

  defp pots_payload(results) do
    results
    |> Map.get(:runs, [])
    |> Enum.flat_map(fn run ->
      Enum.map(Map.get(run, :pots, []), fn pot ->
        %{
          run: run.run,
          amount: pot.amount,
          winners: pot.winners,
          eligible: Map.get(pot, :eligible, pot.winners)
        }
      end)
    end)
  end

  # --- EV --------------------------------------------------------------------

  # Слои банка, сложенные обратно из прогонов. Run it twice делит **каждый**
  # слой между прогонами, поэтому доля эквити умножается на восстановленный
  # слой целиком: эквити не зависит от того, сколько раз доводили борд, и
  # запись обязана это отражать.
  defp pot_layers(results) do
    results
    |> Map.get(:runs, [])
    |> Enum.flat_map(&Map.get(&1, :pots, []))
    |> Enum.group_by(&Enum.sort(Map.get(&1, :eligible, &1.winners)))
    |> Enum.map(fn {eligible, pots} ->
      %{eligible: eligible, amount: Enum.sum(Enum.map(pots, & &1.amount))}
    end)
  end

  # Доли эквити на момент прекращения торговли: `%{seat => доля}`.
  # Раздача без олл-ина эквити не считала — и EV у неё не существует.
  defp equity_shares(%Report{equity: nil}), do: nil

  defp equity_shares(%Report{equity: equity}) do
    case Enum.find(equity, &(&1.run == 1)) || List.first(equity) do
      %{equity: %{players: players}} -> Map.new(players, &{&1.id, &1.equity})
      _other -> nil
    end
  end

  defp ev_amount(_layers, nil, _seat), do: nil

  defp ev_amount(layers, equity, seat) do
    layers
    |> Enum.reduce(0.0, fn layer, acc ->
      if seat in layer.eligible do
        acc + layer.amount * Map.get(equity, seat, 0.0)
      else
        acc
      end
    end)
    |> round()
  end

  # --- действия --------------------------------------------------------------

  # Лог собирается из тех же событий, что ушли в broadcast: одни и те же
  # факты, два потребителя (§7 CLAUDE.md). Вынужденные ставки — такие же
  # строки, иначе реплей начинается с необъяснимого банка.
  defp actions(%Report{} = report, hand) do
    starting = starting_stacks(hand)

    state = %{
      street: :preflop,
      bet: 0,
      committed: %{},
      seq: 0,
      at: List.first(report.log, %{at: 0}).at,
      rows: []
    }

    report.log
    |> Enum.reduce(state, &track(&2, &1, report.hand_id, starting))
    |> Map.fetch!(:rows)
    |> Enum.reverse()
  end

  defp starting_stacks(hand) do
    payouts = (hand.results && hand.results.payouts) || %{}

    Map.new(hand.players, fn {seat, player} ->
      {seat, player.stack - Map.get(payouts, seat, 0) + player.total}
    end)
  end

  defp track(state, %{event: {:street_dealt, %{street: street}}}, _hand_id, _starting) do
    %{state | street: street, bet: 0, committed: %{}}
  end

  defp track(state, %{event: {:posted, payload}} = entry, hand_id, starting) do
    committed = Map.get(state.committed, payload.seat, 0) + payload.amount
    stack_after = Map.get(starting, payload.seat, 0) - committed

    state
    |> put_row(hand_id, entry, %{
      street: state.street,
      seat: payload.seat,
      action: posted_action(payload.kind),
      amount: payload.amount,
      to_amount: committed,
      pot_before: payload.pot - payload.amount,
      stack_after: stack_after
    })
    |> Map.put(:committed, Map.put(state.committed, payload.seat, committed))
    |> Map.put(:bet, max(state.bet, committed))
  end

  defp track(state, %{event: {:action_taken, payload}} = entry, hand_id, _starting) do
    {action, amount, to} = decode_action(state, payload)

    state
    |> put_row(hand_id, entry, %{
      street: state.street,
      seat: payload.seat,
      action: action,
      amount: amount,
      to_amount: to,
      pot_before: payload.pot - amount,
      stack_after: payload.stack
    })
    |> Map.put(:committed, Map.put(state.committed, payload.seat, to))
    |> Map.put(:bet, max(state.bet, to))
  end

  defp track(state, _entry, _hand_id, _starting), do: state

  defp put_row(state, hand_id, entry, row) do
    seq = state.seq + 1

    row =
      row
      |> Map.merge(%{
        hand_id: hand_id,
        seq: seq,
        elapsed_ms: max(entry.at - state.at, 0),
        auto: entry.auto?
      })

    %{state | seq: seq, at: entry.at, rows: [row | state.rows]}
  end

  defp posted_action("small_blind"), do: :post_blind
  defp posted_action("big_blind"), do: :post_blind
  defp posted_action("straddle"), do: :straddle
  defp posted_action("post"), do: :post
  defp posted_action("dead_post"), do: :dead_post
  defp posted_action(_ante), do: :post_ante

  defp decode_action(state, %{action: "fold"}), do: {:fold, 0, state.bet}

  defp decode_action(state, %{action: "check"}), do: {:check, 0, state.bet}

  defp decode_action(state, %{action: "call"} = payload) do
    amount = Map.get(payload, :amount, 0)
    {:call, amount, Map.get(state.committed, payload.seat, 0) + amount}
  end

  defp decode_action(state, %{action: action} = payload) when action in ["raise", "all_in"] do
    to = Map.get(payload, :to, 0)
    amount = Map.get(payload, :amount, 0)

    # Первая ставка улицы — бет, а не рейз: движку это различие не нужно,
    # а реплею и разбору руки — нужно.
    kind =
      cond do
        action == "all_in" -> :all_in
        state.bet == 0 -> :bet
        true -> :raise
      end

    {kind, amount, to}
  end

  defp decode_action(state, _payload), do: {:check, 0, state.bet}

  # --- китайский покер -------------------------------------------------------

  defp ofc(%Report{hand: hand} = report) do
    results = hand.results || %{}
    showdown = Map.get(results, :showdown, %{seats: %{}})
    against = Map.get(results, :against, %{})
    royalties = royalty_totals(showdown)

    players =
      hand.players
      |> Enum.sort_by(fn {seat, _player} -> seat end)
      |> Enum.map(fn {seat, player} ->
        ofc_player(report, results, showdown, against, royalties, seat, player)
      end)

    %{
      kind: :ofc,
      hand: %{
        id: report.hand_id,
        room_id: report.room_id,
        game_mode: report.game_mode,
        setting_id: report.setting_id,
        hand_number: report.hand_number,
        variant: to_string(Ofc.Hand.id()),
        button_seat: report.button_seat,
        point_value: report.point_value,
        started_at: report.started_at,
        ended_at: report.ended_at
      },
      players: players,
      actions: [],
      stats: stats_rows(report, players)
    }
  end

  defp ofc_player(report, results, showdown, against, royalties, seat, player) do
    seat_view = showdown |> Map.get(:seats, %{}) |> Map.get(seat, %{})
    rows = Map.get(seat_view, :royalties, %{})
    pairs = Map.get(against, seat, %{})

    %{
      ofc_hand_id: report.hand_id,
      user_id: player.id,
      seat: seat,
      box: box(seat_view),
      discards: Enum.map(player.discards, &Card.to_map/1),
      foul: Map.get(seat_view, :foul, false),
      royalties: Map.new(rows, fn {row, value} -> {to_string(row), value} end),
      royalty_total: rows |> Map.values() |> Enum.sum(),
      # Входил ли игрок в раздачу в фантазии и заработал ли её по итогам:
      # вся статистика фантазий выводится из этой пары.
      fantasy: player.fantasy?,
      fantasy_next: results |> Map.get(:fantasy, %{}) |> Map.get(seat, false),
      fantasy_cards: nil,
      points: Map.get(seat_view, :points, 0),
      net: Map.get(seat_view, :delta, 0),
      scoop_count: scoop_count(pairs, royalties, seat),
      line_results: line_results(pairs)
    }
  end

  # Сетка приходит из вскрытия помеченной как карты (`{:cards, list}`):
  # внутри ядра карта — целое число, и разворачивает её транспорт. Здесь
  # тот же разворот, потому что в БД едет JSON.
  defp box(seat_view) do
    seat_view
    |> Map.get(:rows, %{})
    |> Map.new(fn
      {row, {:cards, cards}} -> {to_string(row), Enum.map(cards, &Card.to_map/1)}
      {row, cards} when is_list(cards) -> {to_string(row), Enum.map(cards, &Card.to_map/1)}
    end)
  end

  defp line_results(pairs) do
    pairs
    |> Enum.sort_by(fn {opponent, _points} -> opponent end)
    |> Enum.map(fn {opponent, points} -> %{opponent: opponent, points: points} end)
  end

  # Скуп — все три линии у одного соперника. Роялти в попарную разность
  # входят, поэтому из неё вычитается разница премий: остаётся чистый счёт
  # по линиям, и шесть очков в нём означают скуп однозначно.
  defp scoop_count(pairs, royalties, seat) do
    mine = Map.get(royalties, seat, 0)

    Enum.count(pairs, fn {opponent, points} ->
      points - (mine - Map.get(royalties, opponent, 0)) >= Ofc.Score.lines_max()
    end)
  end

  # Сумма премий по местам: попарная разность их учитывает, и без них
  # скуп не отличить от выигранных линий с крупным роялти.
  defp royalty_totals(showdown) do
    showdown
    |> Map.get(:seats, %{})
    |> Map.new(fn {seat, view} ->
      {seat, view |> Map.get(:royalties, %{}) |> Map.values() |> Enum.sum()}
    end)
  end

  # --- дневной агрегат -------------------------------------------------------

  # Строка агрегата на игрока: то, что переживёт чистку раздач. Считается
  # инкрементально, а не свёрткой перед удалением — свёртка ломается ровно
  # один раз, и восстановить её будет уже неоткуда.
  defp stats_rows(%Report{} = report, players) do
    day = DateTime.to_date(report.ended_at)
    setting_id = report.setting_id || PlayerStatsDaily.no_setting()

    players
    |> Enum.reject(&is_nil(&1.user_id))
    |> Enum.map(fn player ->
      %{
        user_id: player.user_id,
        day: day,
        game_mode: report.game_mode,
        setting_id: setting_id
      }
      |> Map.merge(counters(report, player))
    end)
  end

  defp counters(%Report{game_mode: :ofc_cash} = report, player) do
    entered? = player.fantasy

    zeroes()
    |> Map.merge(%{
      hands: 1,
      net: player.net,
      ofc_points: player.points,
      fantasy_hands: bool(entered?),
      fantasy_entries: bool(not entered? and player.fantasy_next),
      fantasy_holds: bool(entered? and player.fantasy_next),
      fouls: bool(player.foul),
      scoops: player.scoop_count,
      royalty_top: royalty(player, "top"),
      royalty_middle: royalty(player, "middle"),
      royalty_bottom: royalty(player, "bottom")
    })
    |> Map.put(:invested, 0)
    |> Map.put(:won, 0)
    |> Map.merge(seat_stats(report, player))
  end

  defp counters(%Report{} = report, player) do
    # Раздача без олл-ина в EV входит своим фактическим результатом: иначе
    # EV-график разошёлся бы с реальным банкроллом на всех неолл-инных
    # руках, что бессмысленно.
    ev_net = (player.ev_amount || player.won) - player.invested

    zeroes()
    |> Map.merge(%{
      net: player.net,
      invested: player.invested,
      won: player.won,
      ev_net: ev_net,
      rake_paid: rake_share(report, player),
      bb_sum: report.big_blind
    })
    |> Map.merge(seat_stats(report, player))
  end

  # Поведенческие счётчики приходят из `Engine.HandStats` уже посчитанными:
  # стол считает их для показателей сессии, и второй проход по событиям
  # ради тех же чисел не нужен.
  defp seat_stats(%Report{stats: stats}, player) do
    case Map.get(stats, player.seat) do
      %Stats{} = seat_stats ->
        Map.new(Stats.counters(), &{&1, Map.fetch!(seat_stats, &1)})

      _none ->
        %{hands: 1}
    end
  end

  # Рейк раскладывается по вложенному: заплатил тот, чьи фишки в банке.
  # Точнее его не разложить — банк общий, а «рейк с победителя» был бы
  # другой моделью, чем та, по которой он берётся.
  defp rake_share(%Report{}, %{invested: 0}), do: 0

  defp rake_share(%Report{hand: %Hand{} = hand}, player) do
    total = hand.players |> Map.values() |> Enum.reduce(0, &(&1.total + &2))
    rake = (hand.results && Map.get(hand.results, :rake, 0)) || 0

    if total > 0, do: div(rake * player.invested, total), else: 0
  end

  defp rake_share(_report, _player), do: 0

  defp royalty(player, row), do: player.royalties |> Map.get(row, 0)

  defp zeroes, do: Map.new(PlayerStatsDaily.counters(), &{&1, 0})

  defp bool(true), do: 1
  defp bool(false), do: 0
end
