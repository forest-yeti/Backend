defmodule BlockPoker.Repo.Migrations.AddCashGameSitOutTimeout do
  use Ecto.Migration

  def change do
    # Сит-аут ограничен временем, а не числом раздач. Раздача — плохая
    # единица для паузы: за столом на двоих она длится минуту, за полным —
    # десять, и одно и то же «20 раздач» означает совершенно разное время
    # удержания места. Игрок же договаривается с собой в минутах.
    #
    # `sit_out_max_hands` при этом уезжает: он не читался ни одной строкой
    # кода и хранить рядом вторую, неработающую единицу измерения — способ
    # однажды настроить не ту.
    alter table(:cash_game_settings) do
      add :sit_out_timeout_ms, :integer, null: false, default: 300_000
      remove :sit_out_max_hands, :integer, null: false, default: 20
    end
  end
end
