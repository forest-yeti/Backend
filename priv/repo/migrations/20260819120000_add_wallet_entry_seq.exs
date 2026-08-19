defmodule BlockPoker.Repo.Migrations.AddWalletEntrySeq do
  use Ecto.Migration

  # Порядок записей журнала до сих пор задавался парой `inserted_at, id`, и
  # это не порядок вовсе: две операции, попавшие в одну микросекунду (а на
  # Windows часы грубее микросекунды), различались только случайным UUID —
  # выписка возвращала их то так, то этак.
  #
  # `seq` — счётчик самой БД: он монотонен и совпадает с фактическим порядком
  # вставки, чего от журнала и требуется. Колонка с AUTO_INCREMENT обязана
  # быть первой в каком-нибудь индексе, поэтому UNIQUE на ней — не украшение.
  def up do
    execute """
    ALTER TABLE `wallet_entries`
      ADD COLUMN `seq` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT UNIQUE
    """

    create index(:wallet_entries, [:wallet_id, :seq])
  end

  def down do
    drop index(:wallet_entries, [:wallet_id, :seq])
    execute "ALTER TABLE `wallet_entries` DROP COLUMN `seq`"
  end
end
