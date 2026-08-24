defmodule BlockPoker.Repo.Migrations.HistoryCurrency do
  @moduledoc """
  Валюта в истории.

  Все суммы в проекте — целые в минимальных единицах, и масштаб задаёт
  валюта: `main` считается в центах, `play_money` — в целых фишках.
  Без неё клиент не может показать ни одну сумму истории: `1700` это и
  `$17.00`, и семнадцать сотен игровых фишек, а угадывать масштаб денег
  интерфейс не вправе.

  В агрегате валюта входит в первичный ключ по той же причине, по которой
  туда входит режим: строки разных валют складывать нечем.
  """

  use Ecto.Migration

  def up do
    for table <- [:hands, :ofc_hands, :tournament_results] do
      alter table(table) do
        add :currency, :string, null: false, default: "main"
      end
    end

    alter table(:player_stats_daily) do
      add :currency, :string, null: false, default: "main"
    end

    # MySQL перестраивает составной ключ только целиком.
    execute """
    ALTER TABLE player_stats_daily
      DROP PRIMARY KEY,
      ADD PRIMARY KEY (user_id, day, game_mode, setting_id, currency)
    """
  end

  def down do
    execute """
    ALTER TABLE player_stats_daily
      DROP PRIMARY KEY,
      ADD PRIMARY KEY (user_id, day, game_mode, setting_id)
    """

    alter table(:player_stats_daily) do
      remove :currency
    end

    for table <- [:hands, :ofc_hands, :tournament_results] do
      alter table(table) do
        remove :currency
      end
    end
  end
end
