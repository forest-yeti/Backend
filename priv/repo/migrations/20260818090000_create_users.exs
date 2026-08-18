defmodule BlockPoker.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  # Ники регистрозависимы (§2 задачи): `Player` и `player` — разные игроки.
  # MySQL по умолчанию сравнивает строки регистронезависимо, поэтому колонке
  # явно задаётся accent/case-sensitive collation — иначе UNIQUE-индекс молча
  # схлопнет два разных ника в один.
  @name_collation "utf8mb4_0900_as_cs"

  def up do
    create table(:users, primary_key: false, options: "ENGINE=InnoDB DEFAULT CHARSET=utf8mb4") do
      add :id, :binary_id, primary_key: true
      add :name, :string, size: 25, null: false
      add :email, :string, size: 160, null: false
      add :avatar, :string, size: 255, null: false, default: "/users/avatars/default.png"
      add :password_hash, :string, size: 255, null: false
      add :status, :string, size: 20, null: false, default: "active"

      timestamps(type: :utc_datetime_usec)
    end

    execute "ALTER TABLE users MODIFY name VARCHAR(25) COLLATE #{@name_collation} NOT NULL"

    create unique_index(:users, [:name])
    create unique_index(:users, [:email])
  end

  def down do
    drop table(:users)
  end
end
