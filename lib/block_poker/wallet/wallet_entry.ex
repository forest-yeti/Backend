defmodule BlockPoker.Wallet.WalletEntry do
  @moduledoc """
  Запись журнала операций по кошельку — append-only (§6 CLAUDE.md, §8 задачи).

  Разрешён только `INSERT`. `UPDATE` и `DELETE` не делает никто и никогда:
  ошибка компенсируется обратной записью типа `adjustment`, след остаётся.
  Поэтому у схемы нет `updated_at` и нет changeset'а обновления.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BlockPoker.Wallet.UserWallet

  @type t :: %__MODULE__{}

  # `:prize` — выплата за место в турнире. Отдельный тип, а не `cash_out`:
  # cash-out возвращает игроку его же фишки со стола, а приз приходит из
  # призового фонда и с его стеком не связан вовсе. В выписке это разные
  # события, и путать их нельзя.
  @types [:deposit, :buy_in, :cash_out, :rake, :prize, :adjustment]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "wallet_entries" do
    # Порядковый номер записи в журнале. Выдаёт его БД (AUTO_INCREMENT),
    # поэтому он монотонен и не зависит от разрешения часов: сортировать
    # выписку по `inserted_at` нельзя — две операции могут попасть в одну
    # микросекунду, и тогда их порядок не определён.
    #
    # В структуре, вернувшейся из `insert`, поле пустое: MySQL-адаптер Ecto
    # читает после вставки только первичный ключ. Номер появляется при
    # следующем чтении — журналу этого достаточно, наружу он не уходит.
    field :seq, :integer

    field :amount, :integer
    field :type, Ecto.Enum, values: @types
    field :balance_after, :integer
    field :ref_id, :string
    field :idempotency_key, :string
    field :meta, :map

    belongs_to :wallet, UserWallet

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @spec types() :: [atom()]
  def types, do: @types

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:wallet_id, :amount, :type, :balance_after, :ref_id, :idempotency_key, :meta])
    |> validate_required([:wallet_id, :amount, :type, :balance_after, :idempotency_key])
    |> validate_exclusion(:amount, [0], message: "нулевая операция не имеет смысла")
    |> validate_number(:balance_after, greater_than_or_equal_to: 0)
    |> validate_length(:idempotency_key, max: 120)
    |> validate_length(:ref_id, max: 64)
    |> assoc_constraint(:wallet)
    |> unique_constraint(:idempotency_key)
  end
end
