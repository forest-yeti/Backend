defmodule BlockPoker.Repo.Migrations.CreateBanners do
  use Ecto.Migration

  def change do
    create table(:banners,
             primary_key: false,
             options: "ENGINE=InnoDB DEFAULT CHARSET=utf8mb4"
           ) do
      add :id, :binary_id, primary_key: true

      # Место показа. UNIQUE: одно место — один баннер, и это не деталь
      # реализации, а сам контракт ручки `GET /api/banners/:place`, которая
      # отдаёт объект, а не список.
      add :place, :string, size: 64, null: false

      # Имя файла в каталоге картинок, а не URL: адрес раздачи меняется
      # вместе с окружением, и зашивать его в строку значит однажды
      # получить базу, указывающую на прошлый хост.
      add :image_file, :string, size: 255, null: false

      add :helper, :string, size: 500
      add :link, :string, size: 1000

      add :updated_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:banners, [:place])
  end
end
