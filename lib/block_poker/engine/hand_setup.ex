defmodule BlockPoker.Engine.HandSetup do
  @moduledoc """
  Вход раздачи: всё, что нужно движку, чтобы её начать, — и ничего сверх того.

  Ключевое свойство — вынужденные ставки приходят **числами**, а не ссылкой
  на `CashGameSetting`. Кэш берёт их из шаблона, турнир — из текущего уровня
  структуры; движку раздачи это безразлично, и именно поэтому он одинаков
  для обоих (§9 задачи 3).

  Структура чистая: ни кошельков, ни `Repo`, ни процессов.
  """

  alias BlockPoker.Engine.{BettingStructure, BombPot, Straddle, Variant}

  @type player :: %{
          :seat => pos_integer(),
          :id => term(),
          :stack => non_neg_integer(),
          :post => non_neg_integer(),
          :dead_post => non_neg_integer(),
          optional(:fantasy) => boolean()
        }

  @type t :: %__MODULE__{
          variant: Variant.t(),
          players: [player()],
          button_seat: pos_integer(),
          small_blind: non_neg_integer(),
          big_blind: non_neg_integer(),
          ante: non_neg_integer(),
          ante_type: :big_blind | :per_player,
          point_value: non_neg_integer(),
          straddle: Straddle.t() | nil,
          bomb_pot: BombPot.t() | nil,
          run_it_twice_allowed: boolean()
        }

  # Блайнды в обязательные не входят: на анте-столе их нет вовсе, и структура
  # ставок берёт оттуда, откуда положено ей (`BettingStructure`).
  @enforce_keys [:variant, :players, :button_seat]
  defstruct [
    :variant,
    :players,
    :button_seat,
    small_blind: 0,
    big_blind: 0,
    ante: 0,
    ante_type: :big_blind,
    # Стоимость очка для дисциплин без банка: в китайском покере раздача
    # рассчитывается очками, а не потом, и цена очка приходит числом ровно
    # по той же причине, что и блайнды, — движку неоткуда знать про шаблон.
    point_value: 0,
    # Ставка вслепую, объявленная до карт (`Engine.Straddle`). Приходит уже
    # разрешённой — одна на раздачу, с проверенной суммой: выбирать между
    # заявками мест обязан тот, кто их собирал, а не движок раздачи.
    straddle: nil,
    # Выпавший бомб-пот (`Engine.BombPot`): взнос со всех и раздача сразу
    # с флопа. Приходит уже решённым — бросок делает тот, кто владеет
    # источником случайности стола, а не раздача.
    bomb_pot: nil,
    # Разрешение приходит флагом, а не ссылкой на шаблон, — по той же причине,
    # что и блайнды. Дефолт `false`: новый режим и искусственный вариант в
    # тестах получают функцию выключенной молча, а не по забывчивости.
    run_it_twice_allowed: false
  ]

  @doc """
  Структура ставок этой раздачи. Её задаёт вид покера, а не шаблон стола:
  холдем играется на блайндах, Short Deck — на анте кнопки.

  Исключение одно — бомб-пот: он отменяет вынужденные ставки стола на одну
  раздачу и потому подменяет структуру целиком, а не правит её по полям.
  """
  @spec structure(t()) :: BettingStructure.t()
  def structure(%__MODULE__{bomb_pot: %{}}), do: BettingStructure.BombPot
  def structure(%__MODULE__{variant: variant}), do: variant.betting_structure()

  @doc "Раздача с взносом со всех и без префлопа."
  @spec bomb_pot?(t()) :: boolean()
  def bomb_pot?(%__MODULE__{bomb_pot: nil}), do: false
  def bomb_pot?(%__MODULE__{}), do: true

  @doc """
  Сумма фишек, с которой раздача начинается. Инвариант «фишки не возникают
  и не исчезают» проверяется относительно неё.
  """
  @spec total_chips(t()) :: non_neg_integer()
  def total_chips(%__MODULE__{players: players}) do
    Enum.reduce(players, 0, fn player, acc -> acc + player.stack end)
  end

  @doc "Игроки в порядке хода после кнопки — по часовой стрелке."
  @spec order_from_button(t()) :: [player()]
  def order_from_button(%__MODULE__{players: players, button_seat: button}) do
    sorted = Enum.sort_by(players, & &1.seat)
    {before_button, after_button} = Enum.split_while(sorted, &(&1.seat <= button))
    after_button ++ before_button
  end
end
