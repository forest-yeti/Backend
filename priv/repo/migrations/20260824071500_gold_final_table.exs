defmodule BlockPoker.Repo.Migrations.GoldFinalTable do
  @moduledoc """
  Финальный стол одинаков во всей сетке: тёмное золото.

  Цвет финалки опознаёт **стадию**, а не семейство турнира, поэтому
  умолчание в схеме — не косметика, а часть договора с клиентом: он
  берёт цвет из снапшота и не держит своей константы.
  """

  use Ecto.Migration

  def up do
    alter table(:tournament_settings) do
      modify :final_felt_color, :string, size: 9, null: false, default: "#6B5518"
      modify :final_background_color, :string, size: 9, null: false, default: "#191206"
    end

    execute """
    UPDATE tournament_settings
       SET final_felt_color = '#6B5518', final_background_color = '#191206'
    """
  end

  def down do
    alter table(:tournament_settings) do
      modify :final_felt_color, :string, size: 9, null: false, default: "#6E1F2E"
      modify :final_background_color, :string, size: 9, null: false, default: "#1A0A10"
    end
  end
end
