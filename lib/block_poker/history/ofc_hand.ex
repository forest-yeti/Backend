defmodule BlockPoker.History.OfcHand do
  @moduledoc """
  Раздача китайского покера.

  Отдельная таблица, а не общая с холдемом: здесь нет банка, ставок, улиц,
  борда, рейка, позиции, вскрытия и EV — то есть ровно тех полей, вокруг
  которых построены `hands` и `hand_actions`.

  Действия не пишутся вовсе: реплей OFC строится из финальных сеток и
  сбросов, а порядок, в котором игрок клал карты внутри своего хода, не
  влияет ни на результат, ни на анализ.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BlockPoker.History.OfcHandPlayer

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  schema "ofc_hands" do
    field :room_id, :binary_id
    field :game_mode, Ecto.Enum, values: [:ofc_cash]
    field :setting_id, :binary_id
    field :currency, Ecto.Enum, values: [:main, :play_money], default: :main
    field :hand_number, :integer, default: 0
    field :variant, :string

    field :button_seat, :integer
    field :point_value, :integer, default: 0

    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec

    has_many :players, OfcHandPlayer, foreign_key: :ofc_hand_id

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :id,
      :room_id,
      :game_mode,
      :setting_id,
      :currency,
      :hand_number,
      :variant,
      :button_seat,
      :point_value,
      :started_at,
      :ended_at
    ])
    |> validate_required([:id, :room_id, :game_mode, :variant, :ended_at])
  end
end
