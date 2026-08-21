defmodule BlockPoker.SitAndGo.Grid do
  @moduledoc """
  Стандартная сетка гипер-турниров: четыре взноса × две дисциплины ×
  три рассадки × две валюты.

  Сетка живёт в коде, а не в `priv/*.exs`, потому что её таблицы призов —
  предмет проверки, а не данных: тест считает матожидание каждой таблицы
  и падает, если правка увела возврат игроку от договорённых 93%.

  ## Структура уровней

  Гипер: стек 500 фишек, уровень — три минуты. Первый уровень даёт 25
  больших блайндов, к шестому от стека остаётся четыре — турнир на троих
  заканчивается за десяток минут, и это его жанр, а не побочный эффект.

  Short Deck играется на анте кнопки, где блайндов нет вовсе, поэтому его
  уровни несут только анте. Одна и та же лесенка номиналов, разные колонки
  — выбор делает структура ставок варианта, а не сетка.

  ## Таблицы призов

  Множитель применяется к **взносу**, число участников в формулу не входит
  (`Engine.PrizePool`). Отсюда договор, который проверяется тестом:

      E[множитель] = число игроков × 0.93

  То есть 1.86 для 2-max, 2.79 для 3-max и 5.58 для 6-max. Разница между
  этим числом и числом участников — доля рума; рейка с банка в турнире нет.

  Таблицы поэтому **не переносятся между рассадками**: поставить таблицу
  3-max на стол вдвоём значит раздавать 2.79 взноса при двух собранных,
  то есть возвращать 139.5%. У каждой рассадки своя таблица, и сходимость
  каждой проверяет тест.

  Мелкие множители забирает победитель целиком: на `x2` за столом на троих
  второе место получило бы меньше собственного взноса, и «приз» был бы
  переименованным возвратом. Места начинают оплачиваться там, где фонд
  вырастает настолько, что делить его есть смысл.

  ## Потолок одной выплаты

  Матожидание — не выручка. Тир `x10000` выпадает раз на миллион турниров,
  но на столе за $100 это выплата в миллион долларов: разовое обязательство,
  которое отбивается только оборотом в $14 млн. Лотерейный риск такого
  размера рум на баланс не берёт.

  Поэтому хвост обрезается по **абсолютной выплате**, а не по множителю:
  один потолок (`max_prize/0`) на все лимиты, из которого выводится
  предельный множитель каждого взноса. Микролимиты не задеты вовсе —
  там `x10000` это $2 500, и обрезать нечего. Отсекается ровно то, что
  опасно: на $10 уходит `x10000`, на $100 — `x1000` и `x10000`.

  Возврат при этом не «примерно тот же», а **ровно тот же**: шансы
  отрезанных тиров переезжают в верхний выживший, после чего веса двух
  нижних тиров пересчитываются так, чтобы матожидание вернулось к целевому
  (`cap_tail/2`). RTP сходится по построению, а не по подбору, и тест
  проверяет это для каждой пары «рассадка × взнос».

  Платой становится сюжет: на высоких лимитах джекпота больше нет, и это
  осознанно — история про «выиграл десять тысяч взносов» живёт там, где
  ничего руму не стоит.
  """

  alias BlockPoker.SitAndGo

  @starting_stack 500
  @level_seconds 180

  # Лесенка номиналов, общая для обеих дисциплин. Холдем читает её как
  # блайнды, Short Deck — как анте кнопки.
  @ladder [
    {10, 20},
    {15, 30},
    {20, 40},
    {30, 60},
    {40, 80},
    {60, 120},
    {80, 160},
    {100, 200},
    {150, 300},
    {200, 400},
    {300, 600},
    {400, 800}
  ]

  # Взносы в минимальных единицах: $0.25, $1, $10, $100. Для игровых фишек
  # шкала та же — 25 / 100 / 1000 / 10 000 фишек.
  @buy_ins [25, 100, 1_000, 10_000]

  @seatings [2, 3, 6]
  @game_types [:texas_holdem, :short_deck]
  @currencies [:main, :play_money]

  # E[множитель] = 1.86 = 2 × 0.93.
  #
  # Основной множитель здесь **ниже x2**, и это не опечатка: матожидание
  # обязано равняться числу участников, умноженному на возврат, а для
  # двоих это 1.86. Рядом с базовым x2 таблицы 3-max выглядит непривычно,
  # но для игрока heads-up даже мягче: на модальном тире рум удерживает
  # четверть собранного против трети у 3-max.
  #
  # Оплачиваемых мест не больше двух — больше за этим столом не бывает.
  @tiers_2max [
    %{multiplier: 150, chance_ppm: 681_000, payouts: [100]},
    %{multiplier: 200, chance_ppm: 269_000, payouts: [100]},
    %{multiplier: 400, chance_ppm: 40_000, payouts: [100]},
    %{multiplier: 1_000, chance_ppm: 9_000, payouts: [100]},
    %{multiplier: 2_500, chance_ppm: 900, payouts: [80, 20]},
    %{multiplier: 10_000, chance_ppm: 90, payouts: [80, 20]},
    %{multiplier: 100_000, chance_ppm: 9, payouts: [80, 20]},
    %{multiplier: 1_000_000, chance_ppm: 1, payouts: [80, 20]}
  ]

  # E[множитель] = 2.79 = 3 × 0.93.
  @tiers_3max [
    %{multiplier: 200, chance_ppm: 720_250, payouts: [100]},
    %{multiplier: 400, chance_ppm: 204_750, payouts: [100]},
    %{multiplier: 600, chance_ppm: 65_000, payouts: [100]},
    %{multiplier: 1_000, chance_ppm: 9_000, payouts: [100]},
    %{multiplier: 2_500, chance_ppm: 900, payouts: [80, 20]},
    %{multiplier: 10_000, chance_ppm: 90, payouts: [75, 20, 5]},
    %{multiplier: 100_000, chance_ppm: 9, payouts: [75, 20, 5]},
    %{multiplier: 1_000_000, chance_ppm: 1, payouts: [75, 20, 5]}
  ]

  # E[множитель] = 5.58 = 6 × 0.93.
  @tiers_6max [
    %{multiplier: 500, chance_ppm: 764_500, payouts: [65, 35]},
    %{multiplier: 600, chance_ppm: 154_500, payouts: [65, 35]},
    %{multiplier: 800, chance_ppm: 60_000, payouts: [65, 35]},
    %{multiplier: 1_500, chance_ppm: 20_000, payouts: [60, 25, 15]},
    %{multiplier: 2_500, chance_ppm: 900, payouts: [60, 25, 15]},
    %{multiplier: 10_000, chance_ppm: 90, payouts: [50, 25, 15, 10]},
    %{multiplier: 100_000, chance_ppm: 9, payouts: [50, 25, 15, 10]},
    %{multiplier: 1_000_000, chance_ppm: 1, payouts: [50, 25, 15, 10]}
  ]

  # Потолок одной выплаты в минимальных единицах: $10 000. Единственный
  # параметр, которым правится лотерейный риск, — предельные множители
  # каждого взноса выводятся из него.
  @max_prize 1_000_000

  @doc "Потолок одной выплаты в минимальных единицах."
  @spec max_prize() :: pos_integer()
  def max_prize, do: @max_prize

  @doc "Целевой возврат игроку в миллионных долях: 930_000 = 93%."
  @spec target_return_ppm() :: pos_integer()
  def target_return_ppm, do: 930_000

  @spec starting_stack() :: pos_integer()
  def starting_stack, do: @starting_stack

  @doc """
  Базовая таблица рассадки — до обрезки хвоста.

  Отдельно от `prize_tiers/2` потому, что задаёт **форму** распределения:
  лесенку множителей и веса редких тиров. Обрезка производна от неё и от
  взноса.
  """
  @spec prize_tiers(pos_integer()) :: [map()]
  def prize_tiers(2), do: @tiers_2max
  def prize_tiers(3), do: @tiers_3max
  def prize_tiers(6), do: @tiers_6max

  @doc """
  Таблица призов для конкретного стола: рассадка задаёт форму, взнос —
  обрезку хвоста по потолку выплаты.

  Возврат игроку не меняется: см. «Потолок одной выплаты» в описании модуля.
  """
  @spec prize_tiers(pos_integer(), pos_integer()) :: [map()]
  def prize_tiers(seats, buy_in) do
    seats |> prize_tiers() |> cap_tail(buy_in)
  end

  @doc """
  Предельный множитель для взноса: тот, при котором выплата упирается
  в потолок. Возвращается в сотых долях, как и сами множители.
  """
  @spec max_multiplier(pos_integer()) :: pos_integer()
  def max_multiplier(buy_in), do: div(@max_prize * 100, buy_in)

  @doc """
  Обрезает хвост таблицы под взнос, сохраняя матожидание.

  Два шага, и оба механические. Шансы тиров выше потолка переезжают в
  верхний выживший — суммарная вероятность «поймать что-то редкое» не
  меняется, меняется только размер того, что ловится. Затем веса двух
  нижних тиров пересчитываются, чтобы матожидание вернулось к исходному.

  Пересчёт обязан сойтись в целых: дробный вес означал бы, что таблица
  не сходится к целевому возврату точно, а «примерно 93%» — это не
  экономика, а надежда. Несходимость поэтому падает, а не округляется.
  """
  @spec cap_tail([map()], pos_integer()) :: [map()]
  def cap_tail(tiers, buy_in) do
    limit = max_multiplier(buy_in)
    {kept, dropped} = Enum.split_with(tiers, &(&1.multiplier <= limit))

    case dropped do
      [] -> tiers
      _dropped -> kept |> fold_into_top(dropped) |> rebalance(expected_hundredths(tiers))
    end
  end

  # Отрезанные шансы переезжают в верхний выживший тир: редкое событие
  # остаётся таким же редким, но перестаёт быть неподъёмным.
  defp fold_into_top(kept, dropped) do
    moved = Enum.reduce(dropped, 0, &(&1.chance_ppm + &2))
    {front, [top]} = Enum.split(kept, length(kept) - 1)

    front ++ [%{top | chance_ppm: top.chance_ppm + moved}]
  end

  # Веса двух нижних тиров — единственная свободная переменная: их суммарный
  # шанс фиксирован, а соотношение подбирается так, чтобы матожидание
  # таблицы вернулось к целевому.
  defp rebalance([low, next | rest], target) do
    chance = low.chance_ppm + next.chance_ppm

    rest_weight =
      Enum.reduce(rest, 0, fn tier, acc -> acc + tier.chance_ppm * tier.multiplier end)

    numerator = next.multiplier * chance + rest_weight - target
    step = next.multiplier - low.multiplier

    if rem(numerator, step) != 0 do
      raise ArgumentError,
            "обрезка хвоста не сходится в целых весах: остаток #{rem(numerator, step)}"
    end

    low_chance = div(numerator, step)

    [%{low | chance_ppm: low_chance}, %{next | chance_ppm: chance - low_chance} | rest]
  end

  defp expected_hundredths(tiers) do
    Enum.reduce(tiers, 0, fn tier, acc -> acc + tier.chance_ppm * tier.multiplier end)
  end

  @doc """
  Структура уровней для дисциплины: одна лесенка, разные колонки.
  """
  @spec blind_levels(atom()) :: [map()]
  def blind_levels(:short_deck) do
    @ladder
    |> Enum.with_index(1)
    |> Enum.map(fn {{small, _big}, index} ->
      %{
        level: index,
        small_blind: 0,
        big_blind: 0,
        ante: small,
        duration_seconds: @level_seconds
      }
    end)
  end

  def blind_levels(_game_type) do
    @ladder
    |> Enum.with_index(1)
    |> Enum.map(fn {{small, big}, index} ->
      %{
        level: index,
        small_blind: small,
        big_blind: big,
        ante: 0,
        duration_seconds: @level_seconds
      }
    end)
  end

  @doc """
  Тестовый турнир: шанс джекпота задран так, чтобы редкие тиры выпадали
  за несколько попыток, а не за миллион.

  Существует ради одного: проверить путь джекпота целиком — розыгрыш,
  анимацию множителя, дележ фонда на три места и выплату — не дожидаясь
  события с вероятностью `1e-6`. Наблюдать его иначе нельзя, а не
  наблюдаемый путь считается работающим ровно до первого раза.

  Три предохранителя от того, чтобы он утёк в продакшен как образец:

    * **только игровые фишки.** Возврат здесь в сотни раз выше собранного,
      и на реальных деньгах это была бы раздача денег;
    * в сетку (`expand/1`) он не входит и под проверку экономики не
      попадает — его RTP сломан намеренно;
    * имя начинается с «ТЕСТ».

  Копировать его веса в боевую таблицу нельзя ни при каких обстоятельствах.
  """
  @spec test_row() :: %{attrs: map(), levels: [map()], tiers: [map()]}
  def test_row do
    %{
      attrs: %{
        name: "ТЕСТ Short Deck 3-Max PM 200",
        game_type: :short_deck,
        currency: :play_money,
        max_players: 3,
        buy_in: 200,
        starting_stack: @starting_stack,
        # В конец витрины: тестовый стол не должен попадаться игроку раньше
        # боевых.
        sort_order: 9_000
      },
      levels: blind_levels(:short_deck),
      tiers: [
        %{multiplier: 200, chance_ppm: 300_000, payouts: [100]},
        %{multiplier: 1_000, chance_ppm: 200_000, payouts: [100]},
        %{multiplier: 2_500, chance_ppm: 200_000, payouts: [80, 20]},
        %{multiplier: 10_000, chance_ppm: 100_000, payouts: [75, 20, 5]},
        %{multiplier: 100_000, chance_ppm: 100_000, payouts: [75, 20, 5]},
        %{multiplier: 1_000_000, chance_ppm: 100_000, payouts: [75, 20, 5]}
      ]
    }
  end

  @doc """
  Полная сетка: список описаний шаблонов со всем, что нужно для вставки.

  Опции сужают выборку — `:currency`, `:game_type`, `:max_players`.
  """
  @spec expand(keyword()) :: [%{attrs: map(), levels: [map()], tiers: [map()]}]
  def expand(opts \\ []) do
    for currency <- pick(@currencies, opts[:currency]),
        game_type <- pick(@game_types, opts[:game_type]),
        buy_in <- @buy_ins,
        seats <- pick(@seatings, opts[:max_players]) do
      %{
        attrs: %{
          name: name(game_type, seats, currency, buy_in),
          game_type: game_type,
          currency: currency,
          max_players: seats,
          buy_in: buy_in,
          starting_stack: @starting_stack,
          sort_order: sort_order(game_type, seats, buy_in)
        },
        levels: blind_levels(game_type),
        tiers: prize_tiers(seats, buy_in)
      }
    end
  end

  @doc """
  Разворачивает сетку в БД. Идемпотентна: шаблон с тем же естественным
  ключом пропускается, чтобы повторный прогон не сбрасывал правки оператора
  и не задваивал уровни.
  """
  @spec seed([map()]) :: %{
          created: [String.t()],
          skipped: [String.t()],
          failed: [{String.t(), term()}]
        }
  def seed(rows) do
    Enum.reduce(rows, %{created: [], skipped: [], failed: []}, &seed_row/2)
  end

  defp seed_row(row, acc) do
    if exists?(row.attrs) do
      %{acc | skipped: acc.skipped ++ [row.attrs.name]}
    else
      insert_row(row, acc)
    end
  end

  defp insert_row(row, acc) do
    case SitAndGo.create_setting(row.attrs, row.levels, row.tiers) do
      {:ok, _setting} -> %{acc | created: acc.created ++ [row.attrs.name]}
      {:error, reason} -> %{acc | failed: acc.failed ++ [{row.attrs.name, reason}]}
    end
  end

  @doc """
  Перезаливает таблицы призов уже заведённых шаблонов под текущее правило.

  Нужна, когда правило поменялось — например, появился потолок выплаты:
  `seed/1` идемпотентна и существующие шаблоны пропускает, поэтому сама
  их не исправит. Трогаются только строки, совпадающие с сеткой по
  естественному ключу: стол, заведённый оператором вручную, не её дело.
  """
  @spec retier([map()]) :: %{
          updated: [String.t()],
          missing: [String.t()],
          failed: [{String.t(), term()}]
        }
  def retier(rows) do
    Enum.reduce(rows, %{updated: [], missing: [], failed: []}, &retier_row/2)
  end

  defp retier_row(row, acc) do
    case find_setting(row.attrs) do
      nil -> %{acc | missing: acc.missing ++ [row.attrs.name]}
      setting -> apply_tiers(setting, row, acc)
    end
  end

  defp apply_tiers(setting, row, acc) do
    case SitAndGo.replace_prize_tiers(setting, row.tiers) do
      {:ok, _setting} -> %{acc | updated: acc.updated ++ [row.attrs.name]}
      {:error, reason} -> %{acc | failed: acc.failed ++ [{row.attrs.name, reason}]}
    end
  end

  defp find_setting(attrs) do
    SitAndGo.list_settings(enabled: nil, currency: attrs.currency, game_types: [attrs.game_type])
    |> Enum.find(&(&1.buy_in == attrs.buy_in and &1.max_players == attrs.max_players))
  end

  defp exists?(attrs), do: find_setting(attrs) != nil

  defp pick(all, nil), do: all
  defp pick(_all, value) when is_list(value), do: value
  defp pick(_all, value), do: [value]

  defp name(game_type, seats, currency, buy_in) do
    "#{discipline(game_type)} Hyper #{seats}-Max #{amount(currency, buy_in)}"
  end

  defp discipline(:short_deck), do: "Short Deck"
  defp discipline(:texas_holdem), do: "Hold'em"

  defp amount(:main, buy_in), do: "$#{:erlang.float_to_binary(buy_in / 100, decimals: 2)}"
  defp amount(:play_money, buy_in), do: "PM #{buy_in}"

  # Порядок витрины: сперва дисциплина, потом взнос, потом рассадка —
  # так, как игрок ищет стол глазами.
  defp sort_order(game_type, seats, buy_in) do
    discipline_offset = if game_type == :short_deck, do: 1000, else: 0
    discipline_offset + Enum.find_index(@buy_ins, &(&1 == buy_in)) * 10 + seats
  end
end
