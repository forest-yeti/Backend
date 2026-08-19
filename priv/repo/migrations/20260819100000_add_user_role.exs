defmodule BlockPoker.Repo.Migrations.AddUserRole do
  use Ecto.Migration

  def change do
    # Роль наружу не уходит: она нужна серверу, чтобы решить, кому доступен
    # ручной запуск стола. Все существующие учётки — обычные игроки.
    alter table(:users) do
      add :role, :string, null: false, default: "default"
    end
  end
end
