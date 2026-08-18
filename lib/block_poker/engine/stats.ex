defmodule BlockPoker.Engine.Stats do
  @moduledoc """
  Накопленные показатели игрока: счётчики и производные от них проценты.

  Здесь лежат **только числа**. Где эти числа живут и когда обнуляются,
  решает слой стола: в кэше — сессия за одним местом (встал — счётчики
  стёрты), в турнире — весь турнир, включая пересадки. Модуль про это
  ничего не знает и знать не должен: он умеет складывать и делить.

  Числители и знаменатели хранятся раздельно, а не «процент и вес», потому
  что проценты не складываются: `merge/2` обязан оставаться обычной суммой
  счётчиков, иначе объединение двух отрезков сессии даст неверный VPIP.

  Показатели:

    * **VPIP** — доля раздач, где игрок добровольно вложил на префлопе.
      Блайнды и анте добровольным вложением не считаются: их не выбирают.
    * **PFR** — доля раздач с рейзом на префлопе.
    * **3-Bet** — доля *возможностей* сделать ререйз, которыми игрок
      воспользовался. Знаменатель — не раздачи, а моменты, когда до его
      хода на префлопе уже был рейз.
    * **AF** — агрессия на постфлопе: `(беты + рейзы) / коллы`. Не процент,
      а отношение; при нуле коллов оно не определено.
    * **WTSD** — доля вскрытий среди раздач, где игрок увидел флоп.
  """

  @type t :: %__MODULE__{
          hands: non_neg_integer(),
          vpip: non_neg_integer(),
          pfr: non_neg_integer(),
          three_bet_chances: non_neg_integer(),
          three_bets: non_neg_integer(),
          saw_flop: non_neg_integer(),
          showdowns: non_neg_integer(),
          aggressive: non_neg_integer(),
          calls: non_neg_integer()
        }

  defstruct hands: 0,
            vpip: 0,
            pfr: 0,
            three_bet_chances: 0,
            three_bets: 0,
            saw_flop: 0,
            showdowns: 0,
            aggressive: 0,
            calls: 0

  @counters [
    :hands,
    :vpip,
    :pfr,
    :three_bet_chances,
    :three_bets,
    :saw_flop,
    :showdowns,
    :aggressive,
    :calls
  ]

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec counters() :: [atom()]
  def counters, do: @counters

  @doc "Поразрядная сумма: сессия — это сложенные показатели её раздач."
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = left, %__MODULE__{} = right) do
    Enum.reduce(@counters, left, fn counter, acc ->
      Map.put(acc, counter, Map.fetch!(left, counter) + Map.fetch!(right, counter))
    end)
  end

  @doc """
  Витрина показателей: то, что уходит клиенту.

  Проценты считаются **здесь**, а не во view: деление — доменная арифметика,
  и одинаковое округление у всех транспортов важнее удобства (§3 CLAUDE.md).
  Нет знаменателя — `nil`, а не ноль: «не сыграно» и «ноль процентов» для
  игрока разные вещи.
  """
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = stats) do
    %{
      hands: stats.hands,
      vpip: percent(stats.vpip, stats.hands),
      pfr: percent(stats.pfr, stats.hands),
      three_bet: percent(stats.three_bets, stats.three_bet_chances),
      wtsd: percent(stats.showdowns, stats.saw_flop),
      af: aggression_factor(stats),
      # Сырые счётчики агрессии: по ним клиент отличает «коллов не было»
      # (AF не определён) от «игрок пассивен».
      aggressive_actions: stats.aggressive,
      calls: stats.calls
    }
  end

  @doc "Процент от знаменателя, округлённый до целого. Без выборки — `nil`."
  @spec percent(non_neg_integer(), non_neg_integer()) :: non_neg_integer() | nil
  def percent(_part, 0), do: nil
  def percent(part, total), do: round(part * 100 / total)

  @doc "Фактор агрессии. При нуле коллов отношение не определено."
  @spec aggression_factor(t()) :: float() | nil
  def aggression_factor(%__MODULE__{calls: 0}), do: nil

  def aggression_factor(%__MODULE__{} = stats) do
    Float.round(stats.aggressive / stats.calls, 1)
  end
end
