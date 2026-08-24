defmodule BlockPoker.History.OfcHandPlayer do
  @moduledoc """
  Участник раздачи китайского покера.

  Сетка (`box`) была открыта за столом целиком и отдаётся всем — это и
  есть основное содержимое OFC-истории. Сбросы (`discards`) не видит
  никто, включая соперников, поэтому наружу они уходят только своему
  владельцу; в БД пишутся для всех — без них невозможен разбор жалоб.

  Фантазия — не отдельная сущность, а пара булевых полей: входил ли игрок
  в раздачу в фантазии и заработал ли её по итогам. Вся статистика
  фантазий выводится из этой пары, потому что фантазия не длится дольше
  одной раздачи — каждая решает её судьбу заново.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BlockPoker.History.OfcHand

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "ofc_hand_players" do
    belongs_to :ofc_hand, OfcHand
    belongs_to :user, BlockPoker.Accounts.User

    field :seat, :integer

    field :box, :map
    field :discards, {:array, :map}, default: []

    field :foul, :boolean, default: false
    field :royalties, :map
    field :royalty_total, :integer, default: 0

    field :fantasy, :boolean, default: false
    field :fantasy_next, :boolean, default: false
    field :fantasy_cards, :integer

    field :points, :integer, default: 0
    field :net, :integer, default: 0
    field :scoop_count, :integer, default: 0
    field :line_results, {:array, :map}, default: []

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(player, attrs) do
    player
    |> cast(attrs, [
      :ofc_hand_id,
      :user_id,
      :seat,
      :box,
      :discards,
      :foul,
      :royalties,
      :royalty_total,
      :fantasy,
      :fantasy_next,
      :fantasy_cards,
      :points,
      :net,
      :scoop_count,
      :line_results
    ])
    |> validate_required([:ofc_hand_id, :seat])
    |> unique_constraint([:user_id, :ofc_hand_id])
  end
end
