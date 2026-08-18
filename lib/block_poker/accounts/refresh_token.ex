defmodule BlockPoker.Accounts.RefreshToken do
  @moduledoc """
  Refresh-токен. Клиент получает 32 случайных байта в Base64URL, в БД лежит
  только SHA-256 от них — по содержимому таблицы токен не восстановить.
  """

  use Ecto.Schema

  alias BlockPoker.Accounts.User

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "refresh_tokens" do
    field :token_hash, :binary, redact: true
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    belongs_to :user, User

    timestamps(type: :utc_datetime_usec)
  end
end
