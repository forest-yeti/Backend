defmodule BlockPoker.Repo.Migrations.AddCashGameAutoStart do
  use Ecto.Migration

  def change do
    # `true` — привычное поведение кэша: стол стартует сам, как только за ним
    # собралось двое. `false` — первый старт даёт администратор вручную.
    alter table(:cash_game_settings) do
      add :auto_start, :boolean, null: false, default: true
    end
  end
end
