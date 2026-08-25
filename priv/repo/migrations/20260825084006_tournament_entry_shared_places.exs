defmodule BlockPoker.Repo.Migrations.TournamentEntrySharedPlaces do
  @moduledoc """
  Слитые места одновременного вылета.

  Двое, вылетевшие одной раздачей с равным стеком, делят сумму своих мест
  поровну (`Engine.Elimination`). Кто с кем связан, знает только процесс
  в момент вылета — из `place` это не выводится. Без колонки дорасчёт
  джобой (`Workers.SettleTournament`), который поднимает результаты из
  БД, заплатил бы каждому его место целиком и разошёлся бы с тем, что
  игроку уже объявили при вылете.

  `NULL` — обычный одиночный вылет: делить не с кем.
  """

  use Ecto.Migration

  def change do
    alter table(:tournament_entries) do
      add :shared_places, :json
    end
  end
end
