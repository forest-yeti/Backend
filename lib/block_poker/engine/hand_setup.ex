defmodule BlockPoker.Engine.HandSetup do
  @moduledoc """
  Вход раздачи: всё, что нужно движку, чтобы её начать, — и ничего сверх того.

  Ключевое свойство — вынужденные ставки приходят **числами**, а не ссылкой
  на `CashGameSetting`. Кэш берёт их из шаблона, турнир — из текущего уровня
  структуры; движку раздачи это безразлично, и именно поэтому он одинаков
  для обоих (§9 задачи 3).

  Структура чистая: ни кошельков, ни `Repo`, ни процессов.
  """

  alias BlockPoker.Engine.{BettingStructure, Variant}

  @type player :: %{
          seat: pos_integer(),
          id: term(),
          stack: non_neg_integer(),
          post: non_neg_integer(),
          dead_post: non_neg_integer()
        }

  @type t :: %__MODULE__{
          variant: Variant.t(),
          players: [player()],
          button_seat: pos_integer(),
          small_blind: non_neg_integer(),
          big_blind: non_neg_integer(),
          ante: non_neg_integer(),
          ante_type: :big_blind | :per_player,
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
    # Разрешение приходит флагом, а не ссылкой на шаблон, — по той же причине,
    # что и блайнды. Дефолт `false`: новый режим и искусственный вариант в
    # тестах получают функцию выключенной молча, а не по забывчивости.
    run_it_twice_allowed: false
  ]

  @doc """
  Структура ставок этой раздачи. Её задаёт вид покера, а не шаблон стола:
  холдем играется на блайндах, Short Deck — на анте кнопки.
  """
  @spec structure(t()) :: BettingStructure.t()
  def structure(%__MODULE__{variant: variant}), do: variant.betting_structure()

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
