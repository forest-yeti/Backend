defmodule BlockPoker.Repo.Migrations.AddCashGameCode do
  use Ecto.Migration

  @natural_key [:game_type, :currency, :small_blind, :big_blind, :ante, :max_players]

  def up do
    # Код закрытой комнаты: по нему её находят, не видя в лобби. У публичных
    # шаблонов он `NULL`.
    alter table(:cash_game_settings) do
      add :code, :string, size: 6
    end

    create unique_index(:cash_game_settings, [:code], name: :cash_game_settings_code)

    # Естественный ключ дополняется кодом: домашняя игра на тех же блайндах,
    # что и публичный лимит, — законная строка, а не дубль.
    #
    # В индекс входит не сам `code`, а производная от него колонка: MySQL
    # считает `NULL` значения различными, и от `code` напрямую два публичных
    # шаблона с одинаковыми лимитами перестали бы конфликтовать — то есть
    # сид потерял бы идемпотентность. `IFNULL(code, '')` превращает «кода
    # нет» в обычное значение, и прежнее правило продолжает действовать.
    execute """
    ALTER TABLE `cash_game_settings`
      ADD COLUMN `code_key` VARCHAR(6) GENERATED ALWAYS AS (IFNULL(`code`, '')) STORED
    """

    drop unique_index(:cash_game_settings, @natural_key, name: :cash_game_settings_natural_key)

    create unique_index(:cash_game_settings, @natural_key ++ [:code_key],
             name: :cash_game_settings_natural_key
           )
  end

  def down do
    drop unique_index(:cash_game_settings, @natural_key ++ [:code_key],
           name: :cash_game_settings_natural_key
         )

    execute "ALTER TABLE `cash_game_settings` DROP COLUMN `code_key`"

    create unique_index(:cash_game_settings, @natural_key, name: :cash_game_settings_natural_key)

    drop unique_index(:cash_game_settings, [:code], name: :cash_game_settings_code)

    alter table(:cash_game_settings) do
      remove :code
    end
  end
end
