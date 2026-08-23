defmodule BlockPoker.Engine.Seating do
  @moduledoc """
  Балансировка рассадки мультистолового турнира: чистый расчёт пересадок.

  Вход — столы и их составы, выход — список пересадок и список столов на
  снос. Ни процессов, ни сокетов: `TournamentServer` применяет план, но
  не считает его.

  ## Правило

  > Разница в числе игроков между любыми двумя столами турнира
  > не больше одного.

  Из него следует и схлопывание: если явка позволяет убрать стол, его
  убирают — а не оставляют «полные и огрызок». Схлопывание приоритетнее
  выравнивания, потому что лишний стол сам по себе создаёт перекос.

  ## Чего балансировка не делает

  * **Не трогает столы, где идёт раздача.** Игрока пересаживают после
    её конца: карт у него в этот момент нет по построению. Занятый стол
    не может быть ни источником, ни назначением.
  * **Не дарит и не отнимает блайнд.** Уезжает игрок с позиции, наиболее
    «поздней» относительно блайндов, — тот, кто только что заплатил
    большой блайнд и не заплатит его ещё целый круг. Садится он на
    эквивалентную позицию; если такой нет, ждёт большого блайнда
    (`wait_for_bb?`), и это решает уже `Engine.EntryRules`.
  * **Не двигает одного игрока дважды за одну балансировку.** План
    строится за один проход, и повторная пересадка означала бы, что
    предыдущая была ошибкой.
  """

  @typedoc """
  Стол глазами балансировки. `seats` — карта «номер места → игрок либо
  `nil`»; `busy?` означает идущую раздачу.
  """
  @type table :: %{
          id: term(),
          seats: %{pos_integer() => term() | nil},
          big_blind_seat: pos_integer() | nil,
          busy?: boolean()
        }

  @typedoc """
  Пересадка. `wait_for_bb?` — эквивалентной позиции не нашлось, и игрок
  вступает в игру, дождавшись большого блайнда.
  """
  @type move :: %{
          player: term(),
          from: term(),
          to: term(),
          seat: pos_integer(),
          wait_for_bb?: boolean()
        }

  @typedoc "План: кого пересадить и какие столы после этого закрыть."
  @type plan :: %{moves: [move()], close: [term()]}

  @doc """
  Сколько столов нужно, чтобы рассадить `players` по `table_size`.

  Ноль игроков — ноль столов: турнир, в котором никого не осталось,
  столов не держит.
  """
  @spec tables_needed(non_neg_integer(), pos_integer()) :: non_neg_integer()
  def tables_needed(0, _table_size), do: 0
  def tables_needed(players, table_size), do: div(players + table_size - 1, table_size)

  @doc """
  План балансировки.

  Сначала схлопывание — столы с наименьшим числом игроков расселяются
  по остальным, — потом выравнивание остатка. Занятые раздачей столы
  из расчёта исключаются целиком: их состав в этот момент менять нельзя,
  и план для них построится на следующем проходе.
  """
  @spec plan([table()], pos_integer()) :: plan()
  def plan(tables, table_size) do
    {free, busy} = Enum.split_with(tables, &(not &1.busy?))

    {kept, closed} = choose_closing(free, keep_count(tables, busy, free, table_size))

    %{moves: [], close: Enum.map(closed, & &1.id), retain: MapSet.new()}
    |> evacuate(closed, kept, table_size)
    |> balance(table_size)
    |> finish()
  end

  @doc "Сколько игроков за столом."
  @spec occupancy(table()) :: non_neg_integer()
  def occupancy(%{seats: seats}) do
    Enum.count(seats, fn {_number, player} -> player != nil end)
  end

  @doc """
  Кого увозить со стола: игрока с самой «поздней» позиции относительно
  блайндов — того, кто только что заплатил большой блайнд.

  Он не заплатит его ещё целый круг, поэтому пересадка не отнимает
  у него ставку и не дарит её. Без большого блайнда (стол ещё не
  раздавал) порядок задаёт номер места — лишь бы он был определён.
  """
  @spec departure_order(table()) :: [{pos_integer(), term()}]
  def departure_order(%{seats: seats, big_blind_seat: big_blind_seat}) do
    occupied = for {number, player} <- seats, player != nil, do: {number, player}
    size = map_size(seats)

    case big_blind_seat do
      nil -> Enum.sort_by(occupied, fn {number, _player} -> number end)
      bb -> Enum.sort_by(occupied, fn {number, _player} -> Integer.mod(number - bb, size) end)
    end
  end

  # --- Схлопывание ---------------------------------------------------------

  # Сколько свободных столов оставить.
  #
  # Двух ограничений, а не одного, и второе важнее. Первое — глобальное:
  # столько столов нужно, чтобы рассадить всех, за вычетом тех, что заняты
  # раздачей и никуда не денутся. Второе — вместимость: игроки закрываемых
  # столов пересаживаются **только** на оставшиеся свободные, потому что
  # состав занятого стола посреди раздачи менять нельзя. Его пустые места
  # существуют, но воспользоваться ими сейчас невозможно.
  #
  # Без второго ограничения турнир из занятого стола на одного и двух
  # свободных по одному снёс бы оба свободных: глобально троим хватает
  # одного стола, а физически сесть им некуда. Игроки при этом исчезали бы.
  defp keep_count(tables, busy, free, table_size) do
    total = Enum.reduce(tables, 0, &(occupancy(&1) + &2))
    movable = Enum.reduce(free, 0, &(occupancy(&1) + &2))

    global = tables_needed(total, table_size) - length(busy)
    capacity = tables_needed(movable, table_size)

    global |> max(capacity) |> max(0) |> min(length(free))
  end

  # Убирается стол с наименьшим числом игроков: пересадок от этого меньше
  # всего. `id` в ключе — чтобы выбор был детерминирован при равенстве.
  defp choose_closing(free, keep_count) do
    sorted = Enum.sort_by(free, &{-occupancy(&1), &1.id})

    {Enum.take(sorted, keep_count), Enum.drop(sorted, keep_count)}
  end

  defp evacuate(state, closed, kept, table_size) do
    movers =
      Enum.flat_map(closed, fn table ->
        Enum.map(departure_order(table), fn {seat, player} ->
          %{player: player, from: table.id, seat: seat, table: table}
        end)
      end)

    Enum.reduce(movers, Map.put(state, :tables, kept), fn mover, acc ->
      seat_somewhere(acc, mover, table_size)
    end)
  end

  # Игрок садится за наименее заполненный стол: так пересадки сразу
  # ложатся ровно и второй проход выравнивания оказывается почти не нужен.
  #
  # Если сесть некуда, стол **не закрывается**: игрок остаётся там, где
  # сидел. Расчёт вместимости этого случая не допускает, но цена ошибки
  # здесь — пропавший из турнира игрок, и страховка дешевле разбирательства.
  defp seat_somewhere(state, mover, table_size) do
    case Enum.filter(state.tables, &(occupancy(&1) < table_size)) do
      [] ->
        %{state | retain: MapSet.put(state.retain, mover.from)}

      candidates ->
        target = Enum.min_by(candidates, &{occupancy(&1), &1.id})
        place(state, mover, target)
    end
  end

  # --- Выравнивание --------------------------------------------------------

  # Цикл, а не одна перестановка: после схлопывания перекос может остаться
  # больше единицы, и правило «разница не больше одного» обязано держаться
  # по завершении плана, а не приближаться к нему.
  defp balance(state, table_size) do
    tables = state.tables

    if length(tables) < 2 do
      state
    else
      fullest = Enum.max_by(tables, &{occupancy(&1), &1.id})
      emptiest = Enum.min_by(tables, &{occupancy(&1), &1.id})

      if occupancy(fullest) - occupancy(emptiest) <= 1 or occupancy(emptiest) >= table_size do
        state
      else
        state
        |> move_one(fullest, emptiest)
        |> balance(table_size)
      end
    end
  end

  defp move_one(state, from, to) do
    # Уже пересаженного не двигаем второй раз: план строится за один
    # проход, и повторная пересадка означала бы ошибку предыдущей.
    moved = MapSet.new(state.moves, & &1.player)

    case Enum.find(departure_order(from), fn {_seat, player} -> player not in moved end) do
      nil ->
        state

      {seat, player} ->
        place(state, %{player: player, from: from.id, seat: seat, table: from}, to)
    end
  end

  # --- Посадка -------------------------------------------------------------

  defp place(state, mover, target) do
    {seat, equivalent?} = pick_seat(mover, target)

    move = %{
      player: mover.player,
      from: mover.from,
      to: target.id,
      seat: seat,
      wait_for_bb?: not equivalent?
    }

    %{
      state
      | moves: [move | state.moves],
        tables: replace(state.tables, occupy(target, seat, mover.player), vacate(mover))
    }
  end

  # Эквивалентная позиция — та же дистанция до большого блайнда: так
  # пересадка не меняет, через сколько рук игрок снова платит. Если такой
  # свободной позиции нет, садимся куда есть, но с ожиданием блайнда.
  defp pick_seat(mover, target) do
    free = for {number, nil} <- target.seats, do: number

    case equivalent_seat(mover, target, free) do
      nil -> {Enum.min(free), false}
      seat -> {seat, true}
    end
  end

  defp equivalent_seat(%{table: %{big_blind_seat: nil}}, _target, _free), do: nil
  defp equivalent_seat(_mover, %{big_blind_seat: nil}, _free), do: nil

  defp equivalent_seat(mover, target, free) do
    wanted = Integer.mod(mover.seat - mover.table.big_blind_seat, map_size(mover.table.seats))
    size = map_size(target.seats)

    Enum.find(free, fn number ->
      Integer.mod(number - target.big_blind_seat, size) == wanted
    end)
  end

  defp occupy(table, seat, player) do
    %{table | seats: Map.put(table.seats, seat, player)}
  end

  # Стол-источник обновляется, только если он остался в игре: у
  # схлопываемого стола состав уже не важен, его снесут целиком.
  defp vacate(mover), do: {mover.from, mover.seat}

  defp replace(tables, updated, {from_id, seat}) do
    Enum.map(tables, fn table ->
      cond do
        table.id == updated.id -> updated
        table.id == from_id -> %{table | seats: Map.put(table.seats, seat, nil)}
        true -> table
      end
    end)
  end

  defp finish(state) do
    %{moves: Enum.reverse(state.moves), close: state.close -- MapSet.to_list(state.retain)}
  end
end
