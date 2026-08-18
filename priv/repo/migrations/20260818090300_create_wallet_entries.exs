defmodule BlockPoker.Repo.Migrations.CreateWalletEntries do
  use Ecto.Migration

  # Append-only журнал операций: разрешён только INSERT. Ошибки компенсируются
  # обратной записью `adjustment`, поэтому `updated_at` тут не нужен.
  def change do
    create table(:wallet_entries,
             primary_key: false,
             options: "ENGINE=InnoDB DEFAULT CHARSET=utf8mb4"
           ) do
      add :id, :binary_id, primary_key: true

      add :wallet_id, references(:user_wallets, type: :binary_id, on_delete: :nothing),
        null: false

      add :amount, :bigint, null: false
      add :type, :string, size: 20, null: false
      add :balance_after, :bigint, null: false
      add :ref_id, :string, size: 64
      add :idempotency_key, :string, size: 120, null: false
      add :meta, :json

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # Единственная защита от двойного списания.
    create unique_index(:wallet_entries, [:idempotency_key])
    # Выписка по кошельку.
    create index(:wallet_entries, [:wallet_id, :inserted_at])

    create constraint(:wallet_entries, :wallet_entries_amount_not_zero, check: "amount <> 0")
  end
end
