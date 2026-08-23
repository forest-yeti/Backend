defmodule BlockPoker.Engine.TournamentPayout do
  @moduledoc """
  Расчёт призовых MTT: сетка + явка + фонд → список выплат по местам.

  Чистый модуль: числа на входе, числа на выходе. Ни БД, ни процессов,
  ни часов.

  ## Почему сетка, а не массив долей

  В Sit & Go число участников известно заранее, и таблица призов может
  быть фиксированной. В MTT явка выясняется только на закрытии поздней
  регистрации: тот же шаблон соберёт и 7 человек, и 300. Фиксированный
  массив на малой явке платил бы три места из четырёх игроков, то есть
  возвращал бы взносы под видом призов.

  Поэтому строка привязана к **интервалу явки** и **интервалу мест**,
  а «явка» — это число **входов**, а не людей: фонд собран с 70 взносов,
  и делить его по сетке для 50 значило бы платить первому месту
  полуторную долю.

  ## Три вещи, которые модуль делает сверх деления

  1. **Усечение по живым людям.** 70 входов могут дать 50 уникальных
     участников, и сетка на 60 мест физически неисполнима. Число
     оплачиваемых мест усекается до числа людей, а доли усечённых мест
     перераспределяются пропорционально по оставшимся.
  2. **Билеты.** Билетная строка — это саттелит. `share_ppm` считается
     от **денежной части** фонда, то есть от фонда за вычетом номиналов
     выданных билетов.
  3. **Переполнение билетов.** Если билетов по сетке выходит больше, чем
     позволяет фонд, билеты выдаются сверху вниз, пока хватает денег;
     места, которым билета не досталось, получают деньги.

  ## Инвариант

  `Σ выплаченных денег + Σ номиналов выданных билетов == фонд` **ровно**.
  Остаток от любого целочисленного деления достаётся первому месту —
  детерминированно, без float. Проверяется property-тестом; расхождение
  здесь создавало бы или уничтожало деньги мимо журнала.
  """

  @ppm 1_000_000

  @typedoc """
  Строка сетки. `entries_to: nil` — «и выше»; `ticket` — номинал билета
  и его идентификатор либо `nil` у денежной строки.
  """
  @type row :: %{
          entries_from: pos_integer(),
          entries_to: pos_integer() | nil,
          place_from: pos_integer(),
          place_to: pos_integer(),
          share_ppm: pos_integer() | nil,
          ticket_id: term() | nil,
          ticket_value: non_neg_integer() | nil
        }

  @typedoc """
  Выплата за одно место. `ticket_id` не `nil` — место получило билет;
  `amount` при этом обычно нулевой, но не обязан им быть: остаток фонда,
  которому больше некуда деться, доплачивается деньгами.
  """
  @type payout :: %{
          place: pos_integer(),
          amount: non_neg_integer(),
          ticket_id: term() | nil,
          ticket_value: non_neg_integer()
        }

  @doc "Знаменатель шкалы долей: `share_ppm / ppm()` — доля фонда на место."
  @spec ppm() :: pos_integer()
  def ppm, do: @ppm

  @doc """
  Призовой фонд и оверлей.

  `collected` — сумма **призовых частей** взносов: `entry_fee` в неё не
  входит (доход рума), `bounty_part` — тоже (её платят друг другу игроки).
  Гарантия относится только к призовому фонду, и оверлей покрывает
  разницу именно с ним.
  """
  @spec pool(non_neg_integer(), non_neg_integer()) ::
          %{prize_pool: non_neg_integer(), overlay: non_neg_integer()}
  def pool(collected, guarantee) when collected >= 0 and guarantee >= 0 do
    %{prize_pool: max(collected, guarantee), overlay: max(0, guarantee - collected)}
  end

  @doc """
  Строки сетки, действующие при данной явке.

  Явка — число **входов**. Диапазоны не пересекаются (проверяет
  `validate/3`), поэтому подходящая полоса ровно одна.
  """
  @spec band([row()], pos_integer()) :: [row()]
  def band(rows, entries) do
    rows
    |> Enum.filter(&in_band?(&1, entries))
    |> Enum.sort_by(& &1.place_from)
  end

  @doc """
  Выплаты по местам при данной явке, числе живых людей и фонде.

  `entries` выбирает полосу сетки, `players` ограничивает число
  оплачиваемых мест (§6.1: 70 входов могут дать 50 человек), `pool` —
  призовой фонд, уже посчитанный `pool/2`.

  Список отсортирован по месту и не содержит мест без приза.

  Нулевая явка — это пустой список, а не ошибка: витрина показывает сетку
  «при текущей явке» и у анонсированного турнира, в который ещё никто не
  вошёл. Падать на этом значило бы ронять карточку в лобби.
  """
  @spec compute([row()], non_neg_integer(), non_neg_integer(), non_neg_integer()) :: [payout()]
  def compute(_rows, 0, _players, _pool), do: []
  def compute(_rows, _entries, 0, _pool), do: []

  def compute(rows, entries, players, pool)
      when entries > 0 and players > 0 and pool >= 0 do
    rows
    |> band(entries)
    |> expand()
    |> truncate(players)
    |> award_tickets(pool)
    |> award_money(pool)
  end

  @doc """
  Сумма выплаченного: деньги плюс номиналы билетов.

  Существует ради инварианта, а не ради удобства: она обязана быть равна
  фонду, и тест сравнивает именно её.
  """
  @spec total([payout()]) :: non_neg_integer()
  def total(payouts) do
    Enum.reduce(payouts, 0, fn payout, acc -> acc + payout.amount + payout.ticket_value end)
  end

  @doc """
  Число оплачиваемых мест при данной явке — то, что игрок видит как
  «до денег осталось N».
  """
  @spec paid_places([row()], non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def paid_places(_rows, 0, _players), do: 0
  def paid_places(_rows, _entries, 0), do: 0

  def paid_places(rows, entries, players) do
    rows |> band(entries) |> expand() |> truncate(players) |> length()
  end

  # --- Проверка сетки целиком ----------------------------------------------

  @doc """
  Проверка набора строк — то, что нельзя выразить ни constraint'ом, ни
  changeset'ом одной строки, потому что это свойства таблицы целиком.

  Проверяется пять вещей:

    * диапазоны явки покрывают `min_players..max_players` без дыр и без
      пересечений — иначе существует явка, для которой турнир нечем
      закончить;
    * внутри полосы места идут подряд с первого без дыр и пересечений;
    * сумма `share_ppm × число мест` по денежным строкам полосы равна
      `ppm/0` ровно (полоса без денежных строк — чистый саттелит —
      законна);
    * доли не возрастают с местом: первое место не может получить меньше
      второго;
    * `place_to <= entries_from`: нельзя оплачивать больше мест, чем
      гарантированно будет входов в этой полосе.
  """
  @spec validate([row()], pos_integer(), pos_integer()) :: :ok | {:error, atom()}
  def validate([], _min_players, _max_players), do: {:error, :no_payouts}

  def validate(rows, min_players, max_players) do
    with :ok <- validate_coverage(rows, min_players, max_players) do
      rows
      |> Enum.group_by(&{&1.entries_from, &1.entries_to})
      |> Enum.reduce_while(:ok, fn {_key, band}, :ok ->
        case validate_band(band) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  # Полосы обязаны лечь встык и накрыть весь диапазон возможной явки.
  # Дыра означает явку, при которой призов нет вовсе; нахлёст — две
  # взаимоисключающие сетки на одну явку, то есть недетерминированный приз.
  defp validate_coverage(rows, min_players, max_players) do
    bands =
      rows
      |> Enum.map(&{&1.entries_from, &1.entries_to})
      |> Enum.uniq()
      |> Enum.sort_by(fn {from, _to} -> from end)

    case bands do
      [{from, _to} | _rest] when from > min_players -> {:error, :entries_gap}
      _other -> walk_bands(bands, min_players, max_players)
    end
  end

  defp walk_bands([], _cursor, _max_players), do: {:error, :entries_gap}

  defp walk_bands([{_from, nil}], _cursor, _max_players), do: :ok

  defp walk_bands([{_from, to}], _cursor, max_players) do
    if to >= max_players, do: :ok, else: {:error, :entries_gap}
  end

  defp walk_bands([{_from, nil} | _rest], _cursor, _max_players), do: {:error, :entries_overlap}

  defp walk_bands([{_from, to}, {next_from, _} = next | rest], cursor, max_players) do
    cond do
      next_from <= to -> {:error, :entries_overlap}
      next_from > to + 1 -> {:error, :entries_gap}
      true -> walk_bands([next | rest], cursor, max_players)
    end
  end

  defp validate_band(band) do
    sorted = Enum.sort_by(band, & &1.place_from)

    with :ok <- validate_places(sorted),
         :ok <- validate_shares(sorted) do
      validate_place_ceiling(sorted)
    end
  end

  defp validate_places(sorted) do
    Enum.reduce_while(sorted, {:ok, 0}, fn row, {:ok, previous_to} ->
      cond do
        row.place_from != previous_to + 1 -> {:halt, {:error, :places_not_contiguous}}
        row.place_to < row.place_from -> {:halt, {:error, :places_not_contiguous}}
        true -> {:cont, {:ok, row.place_to}}
      end
    end)
    |> case do
      {:ok, _last} -> :ok
      error -> error
    end
  end

  # Полоса без денежных строк — чистый саттелит, и требовать от неё
  # миллиона бессмысленно: делить нечего, весь фонд уходит в билеты.
  defp validate_shares(sorted) do
    money = Enum.filter(sorted, &(&1.share_ppm != nil))

    total = Enum.reduce(money, 0, &(&2 + &1.share_ppm * places_in(&1)))

    cond do
      money == [] -> :ok
      total != @ppm -> {:error, :shares_do_not_sum}
      not non_increasing?(money) -> {:error, :shares_increase}
      true -> :ok
    end
  end

  defp non_increasing?(money) do
    money
    |> Enum.map(& &1.share_ppm)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [current, next] -> current >= next end)
  end

  defp validate_place_ceiling(sorted) do
    if Enum.all?(sorted, &(&1.place_to <= &1.entries_from)),
      do: :ok,
      else: {:error, :too_many_paid_places}
  end

  defp places_in(row), do: row.place_to - row.place_from + 1

  # --- Расчёт --------------------------------------------------------------

  defp in_band?(%{entries_from: from, entries_to: nil}, entries), do: entries >= from
  defp in_band?(%{entries_from: from, entries_to: to}, entries), do: entries in from..to

  # Строка «места 4-6» разворачивается в три места: дальше вся арифметика
  # идёт по местам, и диапазоны только мешали бы.
  defp expand(band) do
    Enum.flat_map(band, fn row ->
      Enum.map(row.place_from..row.place_to, fn place ->
        %{
          place: place,
          share_ppm: row.share_ppm,
          ticket_id: row.ticket_id,
          ticket_value: row.ticket_value || 0
        }
      end)
    end)
    |> Enum.sort_by(& &1.place)
  end

  # Мест не может быть больше, чем живых людей: сетка на 60 мест при 50
  # участниках физически неисполнима. Доли усечённых мест расходятся
  # пропорционально по оставшимся денежным — детерминированно, остаток
  # первому месту.
  defp truncate(places, players) when length(places) <= players, do: places

  defp truncate(places, players) do
    kept = Enum.take(places, players)
    remaining = Enum.filter(kept, &(&1.share_ppm != nil))
    total = Enum.reduce(remaining, 0, &(&2 + &1.share_ppm))

    if total == 0 do
      kept
    else
      rescale(kept, total)
    end
  end

  defp rescale(kept, total) do
    scaled =
      Enum.map(kept, fn
        %{share_ppm: nil} = place -> place
        place -> %{place | share_ppm: div(place.share_ppm * @ppm, total)}
      end)

    # Остаток шкалы — первому денежному месту, чтобы сумма долей была
    # ровно `ppm/0` и фонд не «усох» на округлении.
    drift = @ppm - Enum.reduce(scaled, 0, fn place, acc -> acc + (place.share_ppm || 0) end)

    bump_first_money(scaled, drift)
  end

  defp bump_first_money(places, 0), do: places

  defp bump_first_money(places, drift) do
    case Enum.find_index(places, &(&1.share_ppm != nil)) do
      nil -> places
      index -> List.update_at(places, index, &%{&1 | share_ppm: &1.share_ppm + drift})
    end
  end

  # Билеты выдаются сверху вниз, пока хватает фонда. Место, которому
  # билета не досталось, становится денежным (`overflow_to_money`):
  # выдать половину билета нельзя, а оставить место без приза — значит
  # потерять деньги из фонда.
  defp award_tickets(places, pool) do
    {awarded, _left} =
      Enum.map_reduce(places, pool, fn
        %{ticket_id: nil} = place, left ->
          {place, left}

        %{ticket_value: value} = place, left when value <= left ->
          {place, left - value}

        place, left ->
          {%{place | ticket_id: nil, ticket_value: 0}, left}
      end)

    awarded
  end

  # Денежная часть — фонд за вычетом номиналов **выданных** билетов.
  # Она делится по долям; если долей в полосе нет вовсе (чистый саттелит),
  # остаток целиком уходит первому месту, которому билета не хватило,
  # а если таких мест нет — первому месту вообще: деньгам из фонда
  # обязано найтись место, иначе инвариант «сумма выплат равна фонду»
  # не держится.
  defp award_money([], _pool), do: []

  defp award_money(places, pool) do
    tickets = Enum.reduce(places, 0, &(&2 + &1.ticket_value))
    money_pool = pool - tickets
    total_ppm = Enum.reduce(places, 0, fn place, acc -> acc + (place.share_ppm || 0) end)

    places
    |> split_money(money_pool, total_ppm)
    |> Enum.map(fn place ->
      %{
        place: place.place,
        amount: place.amount,
        ticket_id: place.ticket_id,
        ticket_value: place.ticket_value
      }
    end)
  end

  defp split_money(places, money_pool, 0) do
    # Долей нет: весь остаток одному месту. Первому, у которого нет
    # билета, — оно и есть «следующее место» из правила о недостающем
    # билете; если билеты у всех, первому месту вообще.
    index = Enum.find_index(places, &(&1.ticket_id == nil)) || 0

    places
    |> Enum.map(&Map.put(&1, :amount, 0))
    |> List.update_at(index, &%{&1 | amount: money_pool})
  end

  defp split_money(places, money_pool, total_ppm) do
    amounts =
      Enum.map(places, fn place ->
        Map.put(place, :amount, div(money_pool * (place.share_ppm || 0), total_ppm))
      end)

    # Остаток от целочисленного деления — первому месту. Детерминированно
    # и без float: расхождение здесь создаёт или уничтожает деньги.
    drift = money_pool - Enum.reduce(amounts, 0, &(&2 + &1.amount))

    List.update_at(amounts, 0, &%{&1 | amount: &1.amount + drift})
  end
end
