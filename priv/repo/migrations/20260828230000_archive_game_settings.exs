defmodule BlockPoker.Repo.Migrations.ArchiveGameSettings do
  @moduledoc """
  Снятый с сетки шаблон помечается, а не удаляется.

  На строку шаблона ссылаются сыгранные раздачи и итоги турниров, и
  реплей читает из неё имя и лимиты стола. Удалённая строка сделала бы
  вчерашний разбор жалобы невозможным ради сегодняшней чистоты списка.
  """

  use Ecto.Migration

  @tables ~w(cash_game_settings ofc_settings sit_n_go_settings tournament_settings)a

  def change do
    for table <- @tables do
      alter table(table) do
        add :archived_at, :utc_datetime_usec
      end
    end
  end
end
