defmodule BlockPoker.Banners.Banner do
  @moduledoc """
  Баннер в одном из мест интерфейса.

  `place` — не свободная строка, а значение из закрытого списка: клиент
  запрашивает место по имени, зашитому в его сборку, и опечатка в панели
  означала бы пустой блок без единой ошибки. Список живёт здесь, потому
  что «какие места вообще бывают» — доменный факт, и панель получает его
  с сервера, а не держит свою копию.

  Имена мест намеренно записаны так же, как в URL и в JSON: `place` —
  это одновременно ключ в базе, сегмент пути и поле ответа, и три разных
  написания одного места породили бы ровно один класс багов.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BlockPoker.Accounts.User

  @type t :: %__MODULE__{}

  @places ~w(
    CashGameLobbyTop
    SitAndGoLobbyTop
    TournamentsLobbyTop
    OfcLobbyTop
    PersonalBlock
    OnRunApplication
  )

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "banners" do
    field :place, :string
    field :image_file, :string
    field :helper, :string
    field :link, :string

    belongs_to :updated_by, User

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Все места показа, в порядке для панели."
  @spec places() :: [String.t()]
  def places, do: @places

  @spec place?(term()) :: boolean()
  def place?(place), do: place in @places

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(banner, attrs) do
    banner
    |> cast(attrs, [:place, :image_file, :helper, :link, :updated_by_id])
    |> validate_required([:place, :image_file])
    |> validate_inclusion(:place, @places)
    |> validate_length(:helper, max: 500)
    |> validate_length(:link, max: 1000)
    |> unique_constraint(:place)
  end
end
