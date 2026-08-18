defmodule BlockPoker.Repo.Migrations.CreateUserWallets do
  use Ecto.Migration

  def change do
    create table(:user_wallets,
             primary_key: false,
             options: "ENGINE=InnoDB DEFAULT CHARSET=utf8mb4"
           ) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :type, :string, size: 20, null: false

      # Целое в минимальных единицах (центы/фишки) — никаких float (§5 CLAUDE.md).
      add :amount, :bigint, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    # Один кошелёк каждого типа на игрока.
    create unique_index(:user_wallets, [:user_id, :type])

    # Второй рубеж на случай, если блокировку строки где-то забудут (§3 задачи).
    create constraint(:user_wallets, :user_wallets_amount_non_negative, check: "amount >= 0")
  end
end
