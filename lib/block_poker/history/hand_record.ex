defmodule BlockPoker.History.HandRecord do
  @moduledoc """
  Сыгранная раздача холдема: кэш, Sit & Go и MTT в одной таблице.

  Все существенные параметры (блайнды, вариант, номинал) **скопированы**
  в строку, а не берутся по ссылке на шаблон: удаление или правка шаблона
  не должны менять уже сыгранное. Поэтому `setting_id` — обычная колонка,
  а не внешний ключ с каскадом.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BlockPoker.History.{HandAction, HandPlayer}

  @type t :: %__MODULE__{}

  @modes [:cash, :sit_and_go, :mtt]
  # Масштаб сумм раздачи: центы у `main`, целые фишки у `play_money`.
  @currencies [:main, :play_money]

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  schema "hands" do
    field :room_id, :binary_id
    field :game_mode, Ecto.Enum, values: @modes
    field :setting_id, :binary_id
    field :currency, Ecto.Enum, values: @currencies, default: :main
    field :tournament_id, :binary_id

    # Номер уровня хранится **вместе** с фактическими номиналами, а не
    # вместо них: числа нужны реплею, номер — человеку. Восстановить номер
    # по блайндам нельзя — структуры правятся, а два уровня могут иметь
    # одинаковые блайнды при разном анте.
    field :level_number, :integer
    field :hand_number, :integer, default: 0
    field :variant, :string

    field :button_seat, :integer
    field :bet_unit, :integer, default: 0
    field :small_blind, :integer, default: 0
    field :big_blind, :integer, default: 0
    field :ante, :integer, default: 0

    field :board, {:array, :map}, default: []
    field :board_2, {:array, :map}
    field :bomb_pot, :integer

    field :pot, :integer, default: 0
    field :rake, :integer, default: 0
    field :pots, {:array, :map}, default: []

    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec

    has_many :players, HandPlayer, foreign_key: :hand_id
    has_many :actions, HandAction, foreign_key: :hand_id

    timestamps(type: :utc_datetime_usec)
  end

  @spec modes() :: [atom()]
  def modes, do: @modes

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :id,
      :room_id,
      :game_mode,
      :setting_id,
      :currency,
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
    |> validate_required([:id, :room_id, :game_mode, :variant, :ended_at])
  end
end
