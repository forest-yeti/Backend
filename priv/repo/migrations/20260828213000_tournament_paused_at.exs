defmodule BlockPoker.Repo.Migrations.TournamentPausedAt do
  use Ecto.Migration

  # Пауза турнира — состояние, которое обязано пережить рестарт ноды.
  # Живи она только в процессе, поднявшийся после перезагрузки турнир
  # молча продолжил бы раздавать посреди разбора инцидента, ради которого
  # его и остановили.
  def change do
    alter table(:tournaments) do
      add :paused_at, :utc_datetime_usec
    end
  end
end
