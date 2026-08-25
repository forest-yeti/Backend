defmodule BlockPoker.Repo.Migrations.CreateAdminPanel do
  use Ecto.Migration

  @moduledoc """
  Панель администратора (задача 8): сессии входа и журнал действий.

  Админский вход живёт отдельно от `refresh_tokens` намеренно: отзыв
  игровых токенов и отзыв доступа в панель — разные операции, и делать их
  одной строкой значило бы выкидывать админа из панели каждый раз, когда
  у него протух игровой клиент.

  `admin_audit` — append-only, без `updated_at`: запись о действии не
  редактируется и не удаляется никогда, иначе она ничего не доказывает.

  Новых типов `wallet_entries` (`admin_credit`, `admin_transfer`) миграция
  не заводит: колонка `type` — строка, и список значений живёт в схеме.
  """

  def change do
    create table(:admin_sessions,
             primary_key: false,
             options: "ENGINE=InnoDB DEFAULT CHARSET=utf8mb4"
           ) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      # Хранится хэш refresh-токена: по содержимому таблицы токен не восстановить.
      add :token_hash, :string, size: 255, null: false
      add :ip, :string, size: 45, null: false
      add :user_agent, :string, size: 255
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      add :last_seen_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:admin_sessions, [:token_hash])
    create index(:admin_sessions, [:user_id])
    create index(:admin_sessions, [:expires_at])

    create table(:admin_audit,
             primary_key: false,
             options: "ENGINE=InnoDB DEFAULT CHARSET=utf8mb4"
           ) do
      add :id, :binary_id, primary_key: true
      add :admin_id, references(:users, type: :binary_id, on_delete: :nothing), null: false

      # Сессия — не `on_delete: :delete_all`: журнал переживает любую
      # чистку сессий, иначе «кто это сделал» теряется вместе с логином.
      #
      # NULL допустим ровно в одном случае — `login_failed`: сессии в этот
      # момент ещё нет, а записать попытку нужно именно тогда, когда она
      # не удалась. Для всех остальных действий сессию требует контекст.
      add :session_id, references(:admin_sessions, type: :binary_id, on_delete: :nothing)

      add :action, :string, size: 40, null: false
      add :subject_type, :string, size: 20, null: false
      add :subject_id, :string, size: 64, null: false
      add :amount, :bigint
      add :currency, :string, size: 20
      add :reason, :string, size: 500
      add :meta, :json
      add :ip, :string, size: 45, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:admin_audit, [:admin_id])
    create index(:admin_audit, [:subject_type, :subject_id])
    create index(:admin_audit, [:inserted_at])
  end
end
