defmodule BlockPoker.Repo.Migrations.CreateClientReleases do
  use Ecto.Migration

  def change do
    create table(:client_releases,
             primary_key: false,
             options: "ENGINE=InnoDB DEFAULT CHARSET=utf8mb4"
           ) do
      add :id, :binary_id, primary_key: true

      # Версия сборки в semver. UNIQUE: одна версия — один файл, иначе
      # «обновись до 1.0.1» перестаёт быть однозначным указанием.
      add :version, :string, size: 64, null: false
      add :file_name, :string, size: 255, null: false
      add :byte_size, :bigint, null: false

      # sha512 в base64 — ровно в том виде, в каком его ждёт
      # `electron-updater` в `latest.yml`.
      add :sha512, :string, size: 128, null: false

      # Обязательное обновление: опубликованный релиз с этим флагом
      # поднимает минимально допустимую версию до себя.
      add :mandatory, :boolean, null: false, default: false

      # Пока `NULL` — черновик: файл лежит на диске, но в фид не попал и
      # клиентам не виден.
      add :published_at, :utc_datetime_usec

      add :notes, :string, size: 500
      add :uploaded_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:client_releases, [:version])
    create unique_index(:client_releases, [:file_name])
    create index(:client_releases, [:published_at])
  end
end
