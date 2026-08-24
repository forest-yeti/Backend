defmodule BlockPoker.History.Queries do
  @moduledoc """
  Чтение истории.

  Три вещи, которые здесь решаются раз и навсегда, чтобы транспорт их не
  решал (§3 CLAUDE.md).

  **Пагинация курсором, а не offset'ом.** Курсор — пара `(ended_at, id)`.
  Offset на растущей таблице даёт дубли и пропуски: пока игрок листает,
  сверху добавляются новые раздачи и сдвигают окно.

  **Две таблицы, один список.** Холдем и китайский покер живут в разных
  таблицах, но для игрока это одна лента с фильтром по режиму. Если
  фильтр не задан, обе выборки берутся курсорными и сливаются по времени.

  **Приватность — здесь, а не в контроллере.** Чужие карманные карты со
  значением `hidden` и чужие OFC-сбросы не покидают этот модуль ни при
  каких параметрах запроса.
  """

  import Ecto.Query

  alias BlockPoker.History.{
    HandAction,
    HandPlayer,
    HandRecord,
    OfcHand,
    OfcHandPlayer,
    PlayerStatsDaily,
    Summary,
    TournamentResult
  }

  alias BlockPoker.Repo

  @max_limit 100

  @typedoc "Курсор страницы: время окончания раздачи и её идентификатор."
  @type cursor :: {DateTime.t(), Ecto.UUID.t()} | nil

  # --- список раздач ---------------------------------------------------------

  @doc """
  Страница своей истории: элементы списка в порядке убывания времени и
  курсор следующей страницы (`nil` — страница последняя).
  """
  @spec list_hands(Ecto.UUID.t(), map()) :: %{items: [map()], cursor: cursor()}
  def list_hands(user_id, opts \\ %{}) do
    limit = limit(opts)
    modes = List.wrap(opts[:game_mode])

    items =
      []
      |> maybe_concat(holdem_list(user_id, opts, limit), modes == [] or holdem?(modes))
      |> maybe_concat(ofc_list(user_id, opts, limit), modes == [] or :ofc_cash in modes)
      |> Enum.sort_by(&{DateTime.to_unix(&1.ended_at, :microsecond), &1.id}, :desc)

    page(items, limit)
  end

  defp holdem?(modes), do: Enum.any?(modes, &(&1 in [:cash, :sit_and_go, :mtt]))

  defp maybe_concat(acc, _items, false), do: acc
  defp maybe_concat(acc, items, true), do: acc ++ items

  defp holdem_list(user_id, opts, limit) do
    HandPlayer
    |> join(:inner, [p], h in HandRecord, on: h.id == p.hand_id)
    |> where([p], p.user_id == ^user_id)
    |> filter_modes(opts[:game_mode])
    |> filter_setting(opts[:setting_id])
    |> filter_period(opts)
    |> filter_won(opts[:only_won])
    |> apply_cursor(opts[:cursor])
    |> order_by([p, h], desc: h.ended_at, desc: h.id)
    |> limit(^(limit + 1))
    |> select([p, h], %{player: p, hand: h})
    |> Repo.all()
    |> Enum.map(&holdem_item/1)
  end

  defp ofc_list(user_id, opts, limit) do
    OfcHandPlayer
    |> join(:inner, [p], h in OfcHand, on: h.id == p.ofc_hand_id)
    |> where([p], p.user_id == ^user_id)
    |> filter_setting(opts[:setting_id])
    |> filter_period(opts)
    |> filter_won(opts[:only_won])
    |> apply_cursor(opts[:cursor])
    |> order_by([p, h], desc: h.ended_at, desc: h.id)
    |> limit(^(limit + 1))
    |> select([p, h], %{player: p, hand: h})
    |> Repo.all()
    |> Enum.map(&ofc_item/1)
  end

  # Строка списка холдема: своя раздача глазами её участника. Чужих карт
  # здесь нет вообще, даже показанных, — список короткий, и незачем.
  defp holdem_item(%{player: player, hand: hand}) do
    %{
      kind: :holdem,
      id: hand.id,
      ended_at: hand.ended_at,
      game_mode: hand.game_mode,
      setting_id: hand.setting_id,
      tournament_id: hand.tournament_id,
      level_number: hand.level_number,
      hand_number: hand.hand_number,
      variant: hand.variant,
      small_blind: hand.small_blind,
      big_blind: hand.big_blind,
      ante: hand.ante,
      board: hand.board,
      board_2: hand.board_2,
      pot: hand.pot,
      seat: player.seat,
      position: player.position,
      hole_cards: player.hole_cards,
      starting_stack: player.starting_stack,
      invested: player.invested,
      won: player.won,
      net: player.net,
      ev_amount: player.ev_amount,
      status: player.status,
      showdown: player.status in [:showdown, :all_in]
    }
  end

  defp ofc_item(%{player: player, hand: hand}) do
    %{
      kind: :ofc,
      id: hand.id,
      ended_at: hand.ended_at,
      game_mode: hand.game_mode,
      setting_id: hand.setting_id,
      hand_number: hand.hand_number,
      variant: hand.variant,
      point_value: hand.point_value,
      seat: player.seat,
      box: player.box,
      # Свои сбросы игрок видит всегда: он их и так знал.
      discards: player.discards,
      foul: player.foul,
      royalties: player.royalties,
      royalty_total: player.royalty_total,
      fantasy: player.fantasy,
      fantasy_next: player.fantasy_next,
      points: player.points,
      net: player.net,
      scoop_count: player.scoop_count
    }
  end

  # --- реплей ----------------------------------------------------------------

  @doc """
  Одна раздача целиком. Чужая — `:not_found`, а не «нет доступа»:
  существование чужой раздачи не подтверждается.
  """
  @spec get_hand(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, :not_found}
  def get_hand(user_id, hand_id) do
    case holdem_replay(user_id, hand_id) do
      {:ok, replay} -> {:ok, replay}
      {:error, :not_found} -> ofc_replay(user_id, hand_id)
    end
  end

  defp holdem_replay(user_id, hand_id) do
    with %HandRecord{} = hand <- Repo.get(HandRecord, hand_id),
         players =
           Repo.all(
             from p in HandPlayer,
               where: p.hand_id == ^hand_id,
               order_by: p.seat,
               preload: [:user]
           ),
         true <- Enum.any?(players, &(&1.user_id == user_id)) do
      actions =
        Repo.all(from a in HandAction, where: a.hand_id == ^hand_id, order_by: a.seq)

      {:ok,
       %{
         kind: :holdem,
         hand: hand_view(hand),
         players: Enum.map(players, &visible_player(&1, user_id)),
         actions: Enum.map(actions, &action_view/1)
       }}
    else
      _other -> {:error, :not_found}
    end
  end

  # Единственное правило выдачи карт, и оно без исключений: карты чужого
  # игрока со значением `hidden` не покидают сервер ни при каких
  # параметрах запроса. Свои игрок видит всегда — он их и так знал.
  defp visible_player(%HandPlayer{} = player, user_id) do
    hidden? = player.user_id != user_id and player.card_visibility == :hidden

    %{
      seat: player.seat,
      user_id: player.user_id,
      # Ник участника: реплей без имён — таблица номеров мест. Место в
      # разных раздачах занимают разные люди, и по одному номеру раздачу
      # не разобрать.
      name: player_name(player),
      position: player.position,
      starting_stack: player.starting_stack,
      hole_cards: if(hidden?, do: [], else: player.hole_cards),
      card_visibility: player.card_visibility,
      invested: player.invested,
      won: player.won,
      net: player.net,
      ev_amount: player.ev_amount,
      status: player.status,
      rank: if(hidden?, do: nil, else: player.rank)
    }
  end

  defp ofc_replay(user_id, hand_id) do
    with %OfcHand{} = hand <- Repo.get(OfcHand, hand_id),
         players =
           Repo.all(
             from p in OfcHandPlayer,
               where: p.ofc_hand_id == ^hand_id,
               order_by: p.seat,
               preload: [:user]
           ),
         true <- Enum.any?(players, &(&1.user_id == user_id)) do
      {:ok,
       %{
         kind: :ofc,
         hand: ofc_hand_view(hand),
         players: Enum.map(players, &visible_ofc(&1, user_id))
       }}
    else
      _other -> {:error, :not_found}
    end
  end

  # Сетка была открыта за столом целиком и отдаётся всем. Сбросы за столом
  # не видит никто, поэтому чужие не покидают сервер никогда.
  defp visible_ofc(%OfcHandPlayer{} = player, user_id) do
    %{
      seat: player.seat,
      user_id: player.user_id,
      name: player_name(player),
      box: player.box,
      discards: if(player.user_id == user_id, do: player.discards, else: []),
      foul: player.foul,
      royalties: player.royalties,
      royalty_total: player.royalty_total,
      fantasy: player.fantasy,
      fantasy_next: player.fantasy_next,
      points: player.points,
      net: player.net,
      scoop_count: player.scoop_count,
      line_results: player.line_results
    }
  end

  # Наружу уходит карта, а не схема: служебные поля Ecto (`__meta__`,
  # незагруженные связи) клиенту не нужны, а транспорт по инварианту §3
  # не имеет права решать, какие доменные поля показать.
  defp hand_view(hand) do
    Map.take(hand, [
      :id,
      :room_id,
      :game_mode,
      :setting_id,
      :tournament_id,
      :level_number,
      :hand_number,
      :variant,
      :button_seat,
      :bet_unit,
      :small_blind,
      :big_blind,
      :ante,
      :board,
      :board_2,
      :bomb_pot,
      :pot,
      :rake,
      :pots,
      :started_at,
      :ended_at
    ])
  end

  defp ofc_hand_view(hand) do
    Map.take(hand, [
      :id,
      :room_id,
      :game_mode,
      :setting_id,
      :hand_number,
      :variant,
      :button_seat,
      :point_value,
      :started_at,
      :ended_at
    ])
  end

  defp action_view(action) do
    Map.take(action, [
      :seq,
      :street,
      :seat,
      :action,
      :amount,
      :to_amount,
      :pot_before,
      :stack_after,
      :elapsed_ms,
      :auto
    ])
  end

  # Ник берётся из связи, а не из копии в раздаче: смена ника должна быть
  # видна и в старых раздачах — это тот же человек. Незагруженная связь
  # даёт `nil`, и клиент рисует место без имени.
  defp player_name(%{user: %{name: name}}) when is_binary(name), do: name
  defp player_name(_player), do: nil

  # --- сводка и график -------------------------------------------------------

  @doc """
  Сводка за период, разрезом по режиму. Читается из агрегатов, поэтому
  работает одинаково и за вчера, и за год, и не зависит от того, живы ли
  ещё сами раздачи.
  """
  @spec stats(Ecto.UUID.t(), map()) :: %{atom() => map()}
  def stats(user_id, opts \\ %{}) do
    PlayerStatsDaily
    |> where([s], s.user_id == ^user_id)
    |> filter_days(opts)
    |> filter_stat_modes(opts[:game_mode])
    |> filter_stat_setting(opts[:setting_id])
    |> group_by([s], s.game_mode)
    |> select(
      [s],
      {s.game_mode,
       %{
         hands: sum(s.hands),
         vpip: sum(s.vpip),
         pfr: sum(s.pfr),
         three_bet_chances: sum(s.three_bet_chances),
         three_bets: sum(s.three_bets),
         saw_flop: sum(s.saw_flop),
         showdowns: sum(s.showdowns),
         aggressive: sum(s.aggressive),
         calls: sum(s.calls),
         net: sum(s.net),
         invested: sum(s.invested),
         won: sum(s.won),
         rake_paid: sum(s.rake_paid),
         ev_net: sum(s.ev_net),
         bb_sum: sum(s.bb_sum),
         ofc_points: sum(s.ofc_points),
         fantasy_hands: sum(s.fantasy_hands),
         fantasy_entries: sum(s.fantasy_entries),
         fantasy_holds: sum(s.fantasy_holds),
         fouls: sum(s.fouls),
         scoops: sum(s.scoops),
         royalty_top: sum(s.royalty_top),
         royalty_middle: sum(s.royalty_middle),
         royalty_bottom: sum(s.royalty_bottom)
       }}
    )
    |> Repo.all()
    |> Map.new(fn {mode, row} -> {mode, Summary.mode(mode, integers(row))} end)
  end

  @doc """
  Точки графика: день, счётчики дня и денежный итог дня. Накопительный
  итог считает клиент — сервер отдаёт слагаемые, а не сумму, чтобы одна
  выборка кормила все кривые сразу.
  """
  @spec graph(Ecto.UUID.t(), map()) :: [map()]
  def graph(user_id, opts \\ %{}) do
    PlayerStatsDaily
    |> where([s], s.user_id == ^user_id)
    |> filter_days(opts)
    |> filter_stat_modes(opts[:game_mode])
    |> filter_stat_setting(opts[:setting_id])
    |> group_by([s], s.day)
    |> order_by([s], asc: s.day)
    |> select([s], %{
      day: s.day,
      hands: sum(s.hands),
      net: sum(s.net),
      ev_net: sum(s.ev_net),
      bb_sum: sum(s.bb_sum),
      ofc_points: sum(s.ofc_points)
    })
    |> Repo.all()
    |> Enum.map(&integers/1)
  end

  # MySQL возвращает `SUM()` как `Decimal`. Наружу счётчики обязаны уйти
  # целыми: они и есть целые — это суммы целых, а `Decimal` в них
  # появляется исключительно как артефакт драйвера.
  defp integers(row) do
    Map.new(row, fn
      {key, %Decimal{} = value} -> {key, Decimal.to_integer(value)}
      {key, value} -> {key, value}
    end)
  end

  # --- турниры ---------------------------------------------------------------

  @doc "Страница сыгранных турниров: строка на каждый вход."
  @spec list_tournaments(Ecto.UUID.t(), map()) :: %{
          items: [TournamentResult.t()],
          cursor: cursor()
        }
  def list_tournaments(user_id, opts \\ %{}) do
    limit = limit(opts)

    items =
      TournamentResult
      |> where([r], r.user_id == ^user_id)
      |> filter_format(opts[:format])
      |> filter_finished(opts)
      |> tournament_cursor(opts[:cursor])
      |> order_by([r], desc: r.finished_at, desc: r.id)
      |> limit(^(limit + 1))
      |> Repo.all()
      |> Enum.map(&tournament_view/1)

    case Enum.split(items, limit) do
      {page, []} -> %{items: page, cursor: nil}
      {page, _rest} -> %{items: page, cursor: tournament_cursor_of(List.last(page))}
    end
  end

  @doc """
  Один турнир: строки входов игрока и его раздачи этого турнира.

  Раздачи вычищенного по сроку турнира — пустой список, а не `404`: сам
  турнир хранится вечно, и половина списка иначе стала бы битой.
  """
  @spec get_tournament(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, :not_found}
  def get_tournament(user_id, tournament_id) do
    entries =
      TournamentResult
      |> where([r], r.user_id == ^user_id and r.tournament_id == ^tournament_id)
      |> order_by([r], asc: r.entry_index)
      |> Repo.all()
      |> Enum.map(&tournament_view/1)

    case entries do
      [] ->
        {:error, :not_found}

      entries ->
        hands =
          HandPlayer
          |> join(:inner, [p], h in HandRecord, on: h.id == p.hand_id)
          |> where([p, h], p.user_id == ^user_id and h.tournament_id == ^tournament_id)
          |> order_by([p, h], asc: h.hand_number)
          |> select([p, h], %{player: p, hand: h})
          |> Repo.all()
          |> Enum.map(&holdem_item/1)

        {:ok, %{entries: entries, hands: hands}}
    end
  end

  @doc """
  Сводка по турнирам: ROI, ITM и средняя финишная позиция.

  Считается **только** отсюда, а не из `player_stats_daily`: там `net`
  турнирных режимов измеряется в фишках, а фишки не деньги (§3.4 задачи).
  Средняя позиция берётся по последнему входу каждого турнира — ранние
  ре-энтри игрока, дошедшего затем до финального стола, не должны портить
  его среднюю позицию, они уже учтены в ROI своими взносами.
  """
  @spec tournament_summary(Ecto.UUID.t(), map()) :: map()
  def tournament_summary(user_id, opts \\ %{}) do
    results =
      TournamentResult
      |> where([r], r.user_id == ^user_id)
      |> filter_format(opts[:format])
      |> filter_finished(opts)
      |> Repo.all()

    cost = Enum.reduce(results, 0, &(TournamentResult.cost(&1) + &2))
    income = Enum.reduce(results, 0, &(TournamentResult.income(&1) + &2))

    last_entries =
      results
      |> Enum.group_by(& &1.tournament_id)
      |> Enum.map(fn {_id, entries} -> Enum.max_by(entries, & &1.entry_index) end)

    placed = Enum.filter(last_entries, &(&1.place != nil and &1.entrants not in [nil, 0]))

    %{
      tournaments: length(last_entries),
      entries: length(results),
      cost: cost,
      income: income,
      profit: income - cost,
      # ROI в промилле: делить целые деньги во view нельзя, а float в
      # деньгах проекту запрещён.
      roi_ppm: if(cost > 0, do: div((income - cost) * 1_000_000, cost), else: nil),
      itm: Enum.count(results, & &1.itm),
      wins: Enum.count(results, &(&1.outcome == :won)),
      prize: Enum.reduce(results, 0, &(&1.prize + &2)),
      bounty_paid: Enum.reduce(results, 0, &(&1.bounty_paid + &2)),
      # Средняя финишная позиция в долях поля: 5-е из 90 и 5-е из 9 —
      # разные достижения, и одним числом мест они несравнимы.
      average_place_ppm: average_place_ppm(placed)
    }
  end

  defp average_place_ppm([]), do: nil

  defp average_place_ppm(entries) do
    sum =
      Enum.reduce(entries, 0, fn entry, acc ->
        acc + div(entry.place * 1_000_000, entry.entrants)
      end)

    div(sum, length(entries))
  end

  # --- фильтры ---------------------------------------------------------------

  defp limit(opts) do
    opts |> Map.get(:limit, 25) |> max(1) |> min(@max_limit)
  end

  defp page(items, limit) do
    case Enum.split(items, limit) do
      {page, []} -> %{items: page, cursor: nil}
      {page, _rest} -> %{items: page, cursor: cursor_of(List.last(page))}
    end
  end

  defp cursor_of(%{ended_at: ended_at, id: id}), do: {ended_at, id}
  defp tournament_cursor_of(%{finished_at: at, id: id}), do: {at, id}

  defp tournament_view(%TournamentResult{} = result) do
    Map.take(result, [
      :id,
      :entry_id,
      :tournament_id,
      :title,
      :format,
      :bounty,
      :entry_kind,
      :entry_index,
      :buy_in,
      :entry_fee,
      :addons_count,
      :addons_cost,
      :prize,
      :bounty_paid,
      :bounty_final,
      :refund,
      :place,
      :entrants,
      :itm,
      :outcome,
      :hands_played,
      :started_at,
      :finished_at
    ])
  end

  defp filter_modes(query, nil), do: query

  defp filter_modes(query, modes) do
    modes = modes |> List.wrap() |> Enum.filter(&(&1 in [:cash, :sit_and_go, :mtt]))
    if modes == [], do: query, else: where(query, [p, h], h.game_mode in ^modes)
  end

  defp filter_setting(query, nil), do: query
  defp filter_setting(query, id), do: where(query, [p, h], h.setting_id == ^id)

  defp filter_period(query, opts) do
    query
    |> then(fn q -> if opts[:from], do: where(q, [p, h], h.ended_at >= ^opts[:from]), else: q end)
    |> then(fn q -> if opts[:to], do: where(q, [p, h], h.ended_at <= ^opts[:to]), else: q end)
  end

  defp filter_won(query, true), do: where(query, [p], p.net > 0)
  defp filter_won(query, _other), do: query

  # Курсор сравнивается парой, а не одним временем: две раздачи могут
  # закончиться в одну микросекунду, и по времени страница их потеряла бы.
  defp apply_cursor(query, nil), do: query

  defp apply_cursor(query, {at, id}) do
    where(query, [p, h], h.ended_at < ^at or (h.ended_at == ^at and h.id < ^id))
  end

  defp tournament_cursor(query, nil), do: query

  defp tournament_cursor(query, {at, id}) do
    where(query, [r], r.finished_at < ^at or (r.finished_at == ^at and r.id < ^id))
  end

  defp filter_days(query, opts) do
    query
    |> then(fn q ->
      if opts[:from], do: where(q, [s], s.day >= ^to_date(opts[:from])), else: q
    end)
    |> then(fn q -> if opts[:to], do: where(q, [s], s.day <= ^to_date(opts[:to])), else: q end)
  end

  defp to_date(%Date{} = date), do: date
  defp to_date(%DateTime{} = at), do: DateTime.to_date(at)

  defp filter_stat_modes(query, nil), do: query

  defp filter_stat_modes(query, modes) do
    modes = List.wrap(modes)
    if modes == [], do: query, else: where(query, [s], s.game_mode in ^modes)
  end

  defp filter_stat_setting(query, nil), do: query
  defp filter_stat_setting(query, id), do: where(query, [s], s.setting_id == ^id)

  defp filter_format(query, nil), do: query

  defp filter_format(query, formats) do
    formats = List.wrap(formats)
    if formats == [], do: query, else: where(query, [r], r.format in ^formats)
  end

  defp filter_finished(query, opts) do
    query
    |> then(fn q -> if opts[:from], do: where(q, [r], r.finished_at >= ^opts[:from]), else: q end)
    |> then(fn q -> if opts[:to], do: where(q, [r], r.finished_at <= ^opts[:to]), else: q end)
  end
end
