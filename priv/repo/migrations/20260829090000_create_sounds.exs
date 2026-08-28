defmodule BlockPoker.Repo.Migrations.CreateSounds do
  use Ecto.Migration

  def change do
    create table(:sounds,
             primary_key: false,
             options: "ENGINE=InnoDB DEFAULT CHARSET=utf8mb4"
           ) do
      add :id, :binary_id, primary_key: true

      # Имя, под которым звук виден в панели. UNIQUE — не строгость ради
      # строгости: список выбирают глазами, и два «Гонга» в нём означают
      # ровно одно — админ проиграет не тот.
      add :title, :string, size: 120, null: false

      # Имя файла в каталоге звуков, а не URL: адрес раздачи меняется
      # вместе с окружением (см. `banners.image_file`).
      add :file, :string, size: 255, null: false

      # Размер и распознанный формат — то, что панель показывает в списке,
      # чтобы не гадать, что за файл лежит под именем.
      add :bytes, :integer, null: false
      add :format, :string, size: 8, null: false

      add :uploaded_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sounds, [:title])
  end
end
