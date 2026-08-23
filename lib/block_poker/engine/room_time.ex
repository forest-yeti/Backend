defmodule BlockPoker.Engine.RoomTime do
  @moduledoc """
  Перевод расписания рума в абсолютное время.

  Расписание ведётся в **местном времени рума** («каждый день в 21:30»),
  а в БД и в протокол уходит UTC. Пояс, а не готовый сдвиг, потому что
  «21:30» — это обещание игроку, а не момент времени: при переходе на
  летнее время турнир обязан остаться в 21:30 по часам игрока, а не
  уехать на час.

  ## Два разрыва

  Два раза в год локальное время перестаёт быть функцией: час либо
  не существует, либо существует дважды. Оба случая обрабатываются
  явно, а не оставляются на умолчание библиотеки.

    * **Несуществующее время** (часы перевели вперёд, 21:30 не было) —
      запуск сдвигается вперёд на длину разрыва. Пропустить запуск
      нельзя: расписание обещало турнир в этот вечер.
    * **Дважды существующее** (часы перевели назад) — берётся **первое**
      вхождение, второе пропускается. Два одинаковых турнира в одну ночь
      — это дубль призового фонда и дубль оверлея, то есть прямой убыток
      рума и разные условия у двух половин участников.

  Модуль чистый: дата, время и имя пояса на входе, `DateTime` в UTC
  на выходе.
  """

  @doc "Пояс рума из конфига. Единственное место, где он читается."
  @spec timezone() :: String.t()
  def timezone do
    Application.get_env(:block_poker, :room_timezone, "Etc/UTC")
  end

  @doc "Текущее местное время рума."
  @spec now(String.t() | nil) :: DateTime.t()
  def now(zone \\ nil) do
    DateTime.shift_zone!(DateTime.utc_now(), zone || timezone())
  end

  @doc """
  «`time` такого-то числа в поясе рума» — в UTC.

  Возвращает `{:ok, utc}` либо `{:error, :skipped}` для второго вхождения
  дважды существующего времени: такой запуск не создаётся вовсе.
  """
  @spec to_utc(Date.t(), Time.t(), String.t() | nil) :: {:ok, DateTime.t()} | {:error, atom()}
  def to_utc(%Date{} = date, %Time{} = time, zone \\ nil) do
    zone = zone || timezone()

    case DateTime.new(date, time, zone) do
      {:ok, local} ->
        {:ok, DateTime.shift_zone!(local, "Etc/UTC")}

      # Часы перевели назад: 02:30 случится дважды. Берём первое
      # вхождение — то, что ещё по старому сдвигу.
      {:ambiguous, first, _second} ->
        {:ok, DateTime.shift_zone!(first, "Etc/UTC")}

      # Часы перевели вперёд: названного времени не было. Сдвигаем на
      # длину разрыва — турнир состоится, просто часом позже по локальным
      # часам, которых в этот день не хватило.
      {:gap, before_gap, after_gap} ->
        shift_over_gap(date, time, zone, before_gap, after_gap)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Ближайшие моменты запуска расписания в окне `[from, to]` (UTC).

  `weekday` — `1..7` (пн..вс) либо `nil` для «каждый день»; `run_on` —
  конкретная дата разового запуска. Окно берётся по локальным датам,
  поэтому перебираются сутки, а не часы: расписание задано временем дня.
  """
  @spec occurrences(map(), DateTime.t(), DateTime.t(), String.t() | nil) :: [DateTime.t()]
  def occurrences(schedule, %DateTime{} = from, %DateTime{} = to, zone \\ nil) do
    zone = zone || timezone()

    schedule
    |> candidate_dates(from, to, zone)
    |> Enum.flat_map(fn date ->
      case to_utc(date, schedule.start_time, zone) do
        {:ok, utc} -> [utc]
        {:error, _reason} -> []
      end
    end)
    |> Enum.filter(&in_window?(&1, from, to))
    |> Enum.sort(DateTime)
  end

  # Разовый запуск — ровно одна дата, и день недели у него игнорируется:
  # дата уже сказала всё, а второй источник правды о том же дне создал бы
  # расписание, которое не срабатывает молча.
  defp candidate_dates(%{repeat: false, run_on: %Date{} = date}, _from, _to, _zone), do: [date]

  defp candidate_dates(%{repeat: false}, _from, _to, _zone), do: []

  defp candidate_dates(%{weekday: weekday}, from, to, zone) do
    first = from |> DateTime.shift_zone!(zone) |> DateTime.to_date()
    last = to |> DateTime.shift_zone!(zone) |> DateTime.to_date()

    # Окно расширяется на сутки в обе стороны: локальная дата запуска
    # может отличаться от UTC-даты границы окна на сдвиг пояса.
    first
    |> Date.add(-1)
    |> Date.range(Date.add(last, 1))
    |> Enum.filter(&matches_weekday?(&1, weekday))
  end

  defp matches_weekday?(_date, nil), do: true
  defp matches_weekday?(date, weekday), do: Date.day_of_week(date) == weekday

  defp in_window?(moment, from, to) do
    DateTime.compare(moment, from) != :lt and DateTime.compare(moment, to) != :gt
  end

  defp shift_over_gap(date, time, zone, before_gap, after_gap) do
    gap = offset(after_gap) - offset(before_gap)

    shifted = Time.add(time, gap, :second)

    case DateTime.new(date, shifted, zone) do
      {:ok, local} -> {:ok, DateTime.shift_zone!(local, "Etc/UTC")}
      {:ambiguous, first, _second} -> {:ok, DateTime.shift_zone!(first, "Etc/UTC")}
      # Двух разрывов подряд не бывает ни в одной зоне IANA; ветка
      # существует ради тотальности, а не ради случая.
      {:gap, _before, after_gap} -> {:ok, DateTime.shift_zone!(after_gap, "Etc/UTC")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp offset(%DateTime{utc_offset: utc_offset, std_offset: std_offset}) do
    utc_offset + std_offset
  end
end
