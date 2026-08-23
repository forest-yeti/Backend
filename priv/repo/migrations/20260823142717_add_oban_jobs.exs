defmodule BlockPoker.Repo.Migrations.AddObanJobs do
  use Ecto.Migration

  @moduledoc """
  Таблицы Oban. Заводятся здесь, а не «когда понадобятся», потому что
  первая же турнирная джоба — отмена недобравшего турнира с возвратом
  денег: она обязана пережить рестарт ноды, а не жить в таймере процесса.

  Движок — `Oban.Engines.Dolphin` (MySQL): стандартные миграции Oban
  рассчитаны на Postgres, поэтому вызывается реализация под MyXQL.
  """

  def up, do: Oban.Migration.up()

  def down, do: Oban.Migration.down(version: 1)
end
