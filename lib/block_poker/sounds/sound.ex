defmodule BlockPoker.Sounds.Sound do
  @moduledoc """
  Загруженный звук в библиотеке панели.

  У звука есть только имя и файл: всё остальное — где и когда его
  проиграли — не свойство звука, а событие, и живёт в журнале
  (`BlockPoker.Sounds`).

  Имя уникально, потому что список выбирают глазами: два одинаковых
  «Гонга» в выпадающем списке гарантируют, что однажды в зал уйдёт не тот.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BlockPoker.Accounts.User

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "sounds" do
    field :title, :string
    field :file, :string
    field :bytes, :integer
    field :format, :string

    belongs_to :uploaded_by, User

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(sound, attrs) do
    sound
    |> cast(attrs, [:title, :file, :bytes, :format, :uploaded_by_id])
    |> validate_required([:title, :file, :bytes, :format])
    |> validate_length(:title, max: 120)
    |> unique_constraint(:title)
  end
end
