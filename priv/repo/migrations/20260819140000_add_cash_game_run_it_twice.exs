defmodule BlockPoker.Repo.Migrations.AddCashGameRunItTwice do
  use Ecto.Migration

  def change do
    # Run it twice — функция кэш-игры и только её: в турнирах фишка означает
    # позицию в структуре мест, и дробление банка по прогонам эту структуру
    # меняет. Поэтому флаг живёт в шаблоне кэша, а не в общей настройке стола.
    #
    # `default: true` на уровне колонки закрывает и существующие строки,
    # и вставки мимо changeset'а — отдельный UPDATE не нужен.
    alter table(:cash_game_settings) do
      add :allowed_run_it_twice, :boolean, null: false, default: true
    end
  end
end
