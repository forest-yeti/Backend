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

  @doc "Целевой возврат игроку в миллионных долях: 930_000 = 93%."
  @spec target_return_ppm() :: pos_integer()
  def target_return_ppm, do: 930_000

  @spec starting_stack() :: pos_integer()
  def starting_stack, do: @starting_stack

  @doc "Таблица призов для рассадки. Она зависит только от числа мест."
  @spec prize_tiers(pos_integer()) :: [map()]
  def prize_tiers(2), do: @tiers_2max
  def prize_tiers(3), do: @tiers_3max
  def prize_tiers(6), do: @tiers_6max

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
        tiers: prize_tiers(seats)
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

  defp exists?(attrs) do
    SitAndGo.list_settings(enabled: nil, currency: attrs.currency, game_types: [attrs.game_type])
    |> Enum.any?(&(&1.buy_in == attrs.buy_in and &1.max_players == attrs.max_players))
  end

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
