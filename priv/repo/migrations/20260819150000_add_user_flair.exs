defmodule BlockPoker.Repo.Migrations.AddUserFlair do
  use Ecto.Migration

  def change do
    # Flair — чисто визуальная метка игрока (цвет ника и прочее оформление):
    # выделить стримера или партнёра за столом. Прав она не даёт никаких и
    # с `role` не связана — та служебная и наружу не уходит вовсе.
    #
    # Хранится строкой, а не enum: набор меток расширяется чаще, чем стоит
    # гонять миграцию, а рисует их всё равно клиент.
    alter table(:users) do
      add :flair, :string, null: false, default: "default"
    end
  end
end
