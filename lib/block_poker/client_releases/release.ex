defmodule BlockPoker.ClientReleases.Release do
  @moduledoc """
  Загруженная сборка клиента.

  Строка появляется вместе с файлом на диске и до публикации ни на что не
  влияет: `published_at: nil` — это черновик, который можно скачать и
  проверить, но которого для клиентов не существует.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BlockPoker.Accounts.User

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "client_releases" do
    field :version, :string
    field :file_name, :string
    field :byte_size, :integer
    field :sha512, :string
    field :mandatory, :boolean, default: false
    field :published_at, :utc_datetime_usec
    field :notes, :string

    belongs_to :uploaded_by, User

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(release, attrs) do
    release
    |> cast(attrs, [
      :version,
      :file_name,
      :byte_size,
      :sha512,
      :mandatory,
      :notes,
      :uploaded_by_id
    ])
    |> validate_required([:version, :file_name, :byte_size, :sha512])
    |> validate_version()
    |> validate_number(:byte_size, greater_than: 0)
    |> validate_length(:notes, max: 500)
    |> unique_constraint(:version)
    |> unique_constraint(:file_name)
  end

  # Версия проверяется здесь, а не в форме панели: «что такое допустимая
  # версия» — доменное правило, и от него зависит сравнение «новее/старее».
  # Невалидная строка сравнивалась бы как нулевая и тихо выбила бы всех.
  defp validate_version(changeset) do
    validate_change(changeset, :version, fn :version, value ->
      case Version.parse(value) do
        {:ok, _parsed} -> []
        :error -> [version: "не является версией вида 1.0.1"]
      end
    end)
  end
end
