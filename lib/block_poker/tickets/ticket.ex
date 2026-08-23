defmodule BlockPoker.Tickets.Ticket do
  @moduledoc """
  Тип билета: во что он пускает и по какой цене.

  `face_value` дублирует цену шаблона **намеренно**. Цена турнира может
  вырасти, а уже выданный билет обязан пускать по старой — иначе оператор
  одним `UPDATE` обесценивает выданные призы. Разницу, если цена выросла,
  доплачивает рум: она попадает в `collected` как обычный взнос.

  Билет — это одновременно вторая форма оплаты входа и вторая форма
  приза. Турнир, в выплатах которого есть билеты, и есть саттелит:
  отдельного признака «саттелит» в шаблоне нет, потому что он выводится
  из сетки и разошёлся бы с ней на первой правке.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BlockPoker.Tickets.UserTicket

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tickets" do
    belongs_to :setting, BlockPoker.Tournaments.TournamentSetting,
      foreign_key: :tournament_setting_id

    field :name, :string
    field :face_value, :integer

    has_many :user_tickets, UserTicket

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [:tournament_setting_id, :name, :face_value])
    |> validate_required([:tournament_setting_id, :name, :face_value])
    |> validate_length(:name, max: 80)
    |> validate_number(:face_value, greater_than_or_equal_to: 0)
    |> assoc_constraint(:setting)
    |> check_constraint(:face_value, name: :tickets_face_value)
  end
end
