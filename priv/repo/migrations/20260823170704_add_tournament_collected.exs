defmodule BlockPoker.Repo.Migrations.AddTournamentCollected do
  use Ecto.Migration

  @moduledoc """
  Собранное в призовой фонд — колонкой, а не вычислением из счётчиков.

  Счётчики входов дают собранное только там, где все входы одинаковой
  цены. Вход по билету её ломает: билет пускает по `face_value`, взятому
  на момент выдачи, и если турнир с тех пор подорожал, разницу
  доплачивает рум. Считать такой вход по сегодняшней цене значило бы
  записать в фонд деньги, которых никто не вносил.

  Поэтому каждый вход прибавляет к `collected` **свою** призовую часть,
  а фонд читается одним числом.
  """

  def change do
    alter table(:tournaments) do
      add :collected, :bigint, null: false, default: 0
    end

    alter table(:tournament_entries) do
      # Сколько этот вход внёс в фонд: нужно для возврата при
      # разрегистрации, чтобы вычесть ровно внесённое, а не пересчитывать
      # цену заново.
      add :credited, :bigint, null: false, default: 0
    end

    create constraint(:tournaments, :tournaments_collected, check: "collected >= 0")
    create constraint(:tournament_entries, :tournament_entries_credited, check: "credited >= 0")
  end
end
