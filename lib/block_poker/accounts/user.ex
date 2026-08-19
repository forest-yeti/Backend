defmodule BlockPoker.Accounts.User do
  @moduledoc """
  Учётная запись игрока.

  Ник регистрозависим (`Player` и `player` — разные игроки), email хранится
  в нижнем регистре. Пароль в БД не лежит — только Argon2-хэш (§9 CLAUDE.md).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BlockPoker.Wallet.UserWallet

  @type t :: %__MODULE__{}

  @statuses [:active, :blocked]
  @roles [:default, :admin]
  @default_avatar "/users/avatars/default.png"

  @name_format ~r/\A[A-Za-z0-9_-]+\z/
  @email_format ~r/\A[^\s@]+@[^\s@,]+\.[^\s@,]+\z/

  @name_min 3
  @name_max 25
  @email_max 160
  # 72 — предел входной строки для Argon2/bcrypt.
  @password_min 8
  @password_max 72

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "users" do
    field :name, :string
    field :email, :string
    field :avatar, :string, default: @default_avatar
    field :status, Ecto.Enum, values: @statuses, default: :active

    # Роль — служебное поле сервера, и клиенту она не отдаётся ни при каких
    # условиях (§9 CLAUDE.md): наружу уходит лишь то, что роль разрешает
    # конкретному игроку за конкретным столом. Назначается `mix user.role`.
    field :role, Ecto.Enum, values: @roles, default: :default

    field :password_hash, :string, redact: true
    field :password, :string, virtual: true, redact: true

    has_many :wallets, UserWallet

    timestamps(type: :utc_datetime_usec)
  end

  @spec default_avatar() :: String.t()
  def default_avatar, do: @default_avatar

  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @spec roles() :: [atom()]
  def roles, do: @roles

  @doc "Changeset смены роли: единственный путь сделать игрока администратором."
  @spec role_changeset(t(), atom() | String.t()) :: Ecto.Changeset.t()
  def role_changeset(user, role) do
    user
    |> cast(%{role: role}, [:role])
    |> validate_required([:role])
  end

  @spec admin?(t()) :: boolean()
  def admin?(%__MODULE__{role: :admin}), do: true
  def admin?(%__MODULE__{}), do: false

  @doc """
  Changeset регистрации.

  Опция `:validate_unique` (по умолчанию `true`) выключает предварительную
  проверку уникальности запросом в БД — она нужна лишь для понятного сообщения,
  окончательное слово всегда за UNIQUE-индексом. Выключается там, где базы нет
  (например, в property-тестах формата ника).
  """
  @spec registration_changeset(t(), map(), keyword()) :: Ecto.Changeset.t()
  def registration_changeset(user, attrs, opts \\ []) do
    unique? = Keyword.get(opts, :validate_unique, true)

    user
    |> cast(attrs, [:name, :email, :password])
    |> validate_required([:name, :email, :password])
    |> validate_name(unique?)
    |> validate_email(unique?)
    |> validate_password()
  end

  defp validate_name(changeset, unique?) do
    changeset
    |> validate_length(:name, min: @name_min, max: @name_max)
    |> validate_format(:name, @name_format,
      message: "допустимы только латиница, цифры, дефис и подчёркивание"
    )
    # Понятная ошибка до попытки вставки; окончательное слово — за UNIQUE-индексом.
    |> maybe_unsafe_unique(:name, unique?)
    |> unique_constraint(:name)
  end

  defp validate_email(changeset, unique?) do
    changeset
    |> update_change(:email, &normalize_email/1)
    |> validate_length(:email, max: @email_max)
    |> validate_format(:email, @email_format, message: "некорректный адрес")
    |> maybe_unsafe_unique(:email, unique?)
    |> unique_constraint(:email)
  end

  defp maybe_unsafe_unique(changeset, _field, false), do: changeset

  defp maybe_unsafe_unique(changeset, field, true),
    do: unsafe_validate_unique(changeset, field, BlockPoker.Repo)

  defp validate_password(changeset) do
    changeset
    |> validate_length(:password, min: @password_min, max: @password_max, count: :bytes)
    |> hash_password()
  end

  defp hash_password(%Ecto.Changeset{valid?: true, changes: %{password: password}} = changeset) do
    changeset
    |> put_change(:password_hash, Argon2.hash_pwd_salt(password))
    |> delete_change(:password)
  end

  defp hash_password(changeset), do: changeset

  @spec normalize_email(String.t()) :: String.t()
  def normalize_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()

  def normalize_email(email), do: email
end
