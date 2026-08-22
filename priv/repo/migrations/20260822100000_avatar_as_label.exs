defmodule BlockPoker.Repo.Migrations.AvatarAsLabel do
  use Ecto.Migration

  @known ~w(First Second Third Four Five)

  # Аватар перестал быть путём к файлу и стал меткой набора: сервер хранит
  # строку, клиент решает, что рисовать. Старые пути смысла не имеют —
  # всё, что не входит в новый список, схлопывается в `First`.
  def up do
    execute("""
    UPDATE users
       SET avatar = 'First'
     WHERE avatar NOT IN (#{Enum.map_join(@known, ", ", &"'#{&1}'")})
    """)

    alter table(:users) do
      modify :avatar, :string, size: 32, null: false, default: "First"
    end
  end

  def down do
    alter table(:users) do
      modify :avatar, :string, size: 255, null: false, default: "/users/avatars/default.png"
    end
  end
end
