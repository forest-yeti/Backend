defmodule BlockPoker.Engine.PrizePool do
  @moduledoc """
  Лотерейный призовой фонд Sit & Go: розыгрыш множителя и раскладка по местам.

  Механика та же, что у Spin & Go: перед первой раздачей стол тянет из
  таблицы **тир** — множитель к взносу — и объявляет его всем сразу.
  Дальше турнир играется обычным порядком, но игроки уже знают, за что.

  ## Почему множитель к взносу, а не к сумме взносов

  Приз считается как `взнос × множитель`, и число участников в формулу
  не входит. Это не деталь, а то, что делает таблицу переносимой: тир `x2`
  за столом на троих означает «фонд равен двум взносам при трёх внесённых»
  — и разница между `3` и `E[множитель]` есть ровно та доля, которую
  оставляет себе рум. Умножай мы ещё и на число игроков, тот же набор
  тиров давал бы возврат втрое выше внесённого.

  Отсюда правило, за которым следит `expected_return_ppm/1`:

      E[множитель] = число игроков × целевой возврат

  Для 3-max при 93% это 2.79, для 6-max — 5.58. Проверяется тестом, а не
  договорённостью: правка таблицы, ломающая экономику, обязана падать в CI.

  ## Шкалы

  Обе целые, дробей нет по тому же правилу, что и у денег (§5 CLAUDE.md):

    * множитель — в сотых долях (`multiplier_scale/0`): `200` = x2.00;
    * шанс — в миллионных (`chance_scale/0`): `750_000` = 75%.

  Сумма шансов таблицы обязана быть ровно `chance_scale/0`. Проверка живёт
  здесь (`valid_chances?/1`), а не в БД: constraint видит одну строку, а
  инвариант — свойство набора.

  Модуль чистый: числа и RNG на входе, числа на выходе.
  """

  alias BlockPoker.Engine.Rng

  @typedoc """
  Один тир таблицы: множитель, его шанс и раскладка фонда по местам.

  `payouts` — проценты, первым победитель: `[100]` или `[75, 20, 5]`.
  Длина списка и есть число оплачиваемых мест этого тира.
  """
  @type tier :: %{
          multiplier: pos_integer(),
          chance_ppm: pos_integer(),
          payouts: [pos_integer()]
        }

  @chance_scale 1_000_000
  @multiplier_scale 100

  @doc "Знаменатель шкалы шанса: `chance_ppm / chance_scale()` — вероятность тира."
  @spec chance_scale() :: pos_integer()
  def chance_scale, do: @chance_scale

  @doc "Знаменатель шкалы множителя: `multiplier / multiplier_scale()` — во сколько раз."
  @spec multiplier_scale() :: pos_integer()
  def multiplier_scale, do: @multiplier_scale

  @doc """
  Тянет тир из таблицы.

  Проход кумулятивный по шансам в том порядке, в каком тиры пришли, —
  порядок на распределение не влияет, но делает розыгрыш воспроизводимым
  по seed вместе со всей раздачей.

  Таблица обязана быть непустой и суммироваться в `chance_scale/0`;
  нарушение — ошибка конфигурации, а не игровая ситуация, поэтому падаем.
  """
  @spec draw(Rng.t(), [tier()]) :: {tier(), Rng.t()}
  def draw(_rng, []), do: raise(ArgumentError, "пустая таблица призовых тиров")

  def draw(rng, tiers) do
    unless valid_chances?(tiers) do
      raise ArgumentError,
            "сумма шансов таблицы должна быть ровно #{@chance_scale}, получено #{total_chance(tiers)}"
    end

    {roll, rng} = Rng.uniform_below(rng, @chance_scale)
    {pick(tiers, roll), rng}
  end

  @doc "Сумма шансов таблицы равна полной шкале."
  @spec valid_chances?([tier()]) :: boolean()
  def valid_chances?(tiers), do: total_chance(tiers) == @chance_scale

  @spec total_chance([tier()]) :: non_neg_integer()
  def total_chance(tiers), do: Enum.reduce(tiers, 0, &(&1.chance_ppm + &2))

  @doc """
  Призовой фонд: взнос, умноженный на множитель тира.

  Делится нацело — фонд обязан быть целым числом минимальных единиц,
  и остаток от деления остаётся руму вместе с его долей.
  """
  @spec prize_pool(pos_integer(), pos_integer()) :: non_neg_integer()
  def prize_pool(buy_in, multiplier) when buy_in > 0 and multiplier > 0 do
    div(buy_in * multiplier, @multiplier_scale)
  end

  @doc """
  Раскладка фонда по местам: список сумм, первым — победителю.

  Остаток от округления долей достаётся первому месту, поэтому сумма
  выплат равна фонду **ровно**. Это не косметика: расхождение здесь
  создавало бы или уничтожало деньги мимо журнала.
  """
  @spec split(non_neg_integer(), [pos_integer()]) :: [non_neg_integer()]
  def split(0, payouts), do: Enum.map(payouts, fn _ -> 0 end)

  def split(pool, [_ | _] = payouts) do
    shares = Enum.map(payouts, &div(pool * &1, 100))
    [first | rest] = shares
    [first + (pool - Enum.sum(shares)) | rest]
  end

  @doc """
  Матожидание множителя таблицы в миллионных долях.

  `2_790_000` — это 2.79 взноса на участника. Возврат игроку — отношение
  этой величины к числу участников; отсюда и проверка экономики.
  """
  @spec expected_multiplier_ppm([tier()]) :: non_neg_integer()
  def expected_multiplier_ppm(tiers) do
    tiers
    |> Enum.reduce(0, fn tier, acc -> acc + tier.chance_ppm * tier.multiplier end)
    |> div(@multiplier_scale)
  end

  @doc """
  Доля взносов, возвращаемая игрокам, в миллионных долях: `930_000` = 93%.

  Всё, что не возвращено, — доход рума. Рейка с банка в Sit & Go нет
  и быть не может: банк здесь в турнирных фишках, а не в деньгах.
  """
  @spec expected_return_ppm([tier()], pos_integer()) :: non_neg_integer()
  def expected_return_ppm(tiers, players) when players > 0 do
    div(expected_multiplier_ppm(tiers), players)
  end

  @doc """
  Множитель словами — то, что клиент рисует на барабане («X2», «X2.5»).

  Считается здесь, а не во view: деление сотых долей на разы — арифметика
  над доменным значением (§3 CLAUDE.md).
  """
  @spec multiplier_label(pos_integer()) :: String.t()
  def multiplier_label(multiplier) when is_integer(multiplier) and multiplier > 0 do
    whole = div(multiplier, @multiplier_scale)

    case rem(multiplier, @multiplier_scale) do
      0 -> "X#{whole}"
      tenths when rem(tenths, 10) == 0 -> "X#{whole}.#{div(tenths, 10)}"
      rest -> "X#{whole}.#{String.pad_leading(Integer.to_string(rest), 2, "0")}"
    end
  end

  # Последний тир забирает хвост шкалы: сумма шансов уже проверена, поэтому
  # `roll` не может выйти за неё, и ветка существует только для тотальности.
  defp pick([tier], _roll), do: tier

  defp pick([tier | rest], roll) do
    if roll < tier.chance_ppm, do: tier, else: pick(rest, roll - tier.chance_ppm)
  end
end
