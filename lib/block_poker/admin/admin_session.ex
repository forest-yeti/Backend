defmodule BlockPoker.Admin.AdminSession do
  @moduledoc """
  Админская сессия: отдельный вход в панель, не взаимозаменяемый с игровым.

  Клиент получает 32 случайных байта в Base64URL, в БД лежит только
  SHA-256 от них — по содержимому таблицы refresh-токен не восстановить.
  Отзыв строки мгновенно закрывает и HTTP, и сокет: и плаг, и `connect/3`
  сверяются с `revoked_at` (§8 задачи 8).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BlockPoker.Accounts.User

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "admin_sessions" do
    field :token_hash, :string, redact: true
    field :ip, :string
    field :user_agent, :string
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec

    belongs_to :user, User

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(session, attrs) do
    session
    |> cast(attrs, [:user_id, :token_hash, :ip, :user_agent, :expires_at, :last_seen_at])
    |> validate_required([:user_id, :token_hash, :ip, :expires_at, :last_seen_at])
    |> validate_length(:user_agent, max: 255)
    |> assoc_constraint(:user)
    |> unique_constraint(:token_hash)
  end

  @doc "Действует ли сессия прямо сейчас."
  @spec active?(t(), DateTime.t()) :: boolean()
  def active?(%__MODULE__{revoked_at: nil, expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) == :gt

  def active?(%__MODULE__{}, _now), do: false
end
