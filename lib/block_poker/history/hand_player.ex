defmodule BlockPoker.History.HandPlayer do
  @moduledoc """
  Участник раздачи холдема.

  Карманные карты пишутся **всем**, кто их получил, включая сфолдивших на
  префлопе: без этого невозможны ни EV, ни разбор жалоб, ни последующая
  античит-аналитика. Наружу они уходят только по `card_visibility`
  (§4 задачи 6), и решает это выдача, а не запись.

  `net`, `invested`, `won` и `ev_amount` лежат рядом с `user_id`
  намеренно: и список, и график, и сводка читаются по одной таблице,
  без join к `hands` в горячем пути.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BlockPoker.History.HandRecord

  @type t :: %__MODULE__{}

  @visibilities [:showdown, :voluntary, :hidden]
  @statuses [:folded, :showdown, :won_uncontested, :all_in]
  @positions [:btn, :sb, :bb, :utg, :utg1, :utg2, :mp, :mp1, :lj, :hj, :co]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "hand_players" do
    belongs_to :hand, HandRecord
    belongs_to :user, BlockPoker.Accounts.User

    field :seat, :integer
    field :position, Ecto.Enum, values: @positions

    field :starting_stack, :integer, default: 0
    field :hole_cards, {:array, :map}, default: []
    field :card_visibility, Ecto.Enum, values: @visibilities, default: :hidden

    field :invested, :integer, default: 0
    field :won, :integer, default: 0
    field :net, :integer, default: 0
    field :ev_amount, :integer

    field :status, Ecto.Enum, values: @statuses
    field :rank, :map

    timestamps(type: :utc_datetime_usec)
  end

  @spec visibilities() :: [atom()]
  def visibilities, do: @visibilities

  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @spec positions() :: [atom()]
  def positions, do: @positions

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(player, attrs) do
    player
    |> cast(attrs, [
      :hand_id,
      :user_id,
      :seat,
      :position,
      :starting_stack,
      :hole_cards,
      :card_visibility,
      :invested,
      :won,
      :net,
      :ev_amount,
      :status,
      :rank
    ])
    |> validate_required([:hand_id, :seat, :status])
    |> unique_constraint([:user_id, :hand_id])
  end
end
