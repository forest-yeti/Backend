defmodule BlockPoker.Repo.Migrations.CreateSitNGo do
  use Ecto.Migration

  @moduledoc """
  Sit & Go: шаблон турнира, его структура уровней и таблица призовых тиров.

  Три таблицы вместо одной, потому что у уровней и тиров кардинальность
  «много на шаблон», а не «поле шаблона»: гипер-структура — это дюжина
  строк, лотерейная таблица — восемь, и обе правятся независимо от лимита.
  """

  def change do
    create table(:sit_n_go_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :name, :string, size: 80
      add :game_type, :string, null: false
      add :currency, :string, null: false

      # Ровно столько игроков собирается перед стартом: у Sit & Go пул
      # не «минимум», а точное число — 3-max стартует тройкой, 6-max шестёркой.
      add :max_players, :integer, null: false

      # Взнос — в минимальных единицах валюты (§5 CLAUDE.md), стартовый
      # стек — в фишках. Это разные величины и разные шкалы: турнирная
      # фишка деньгами не является и в кошелёк не конвертируется.
      add :buy_in, :bigint, null: false
      add :starting_stack, :bigint, null: false

      add :action_timeout_ms, :integer, null: false, default: 15_000
      add :time_bank_ms, :integer, null: false, default: 20_000
      add :time_bank_refill, :integer, null: false, default: 5_000
      add :disconnect_grace_ms, :integer, null: false, default: 30_000
      add :button_draw_animation_ms, :integer, null: false, default: 3_000

      # Пауза между вскрытием приза и первой раздачей: множитель показывается
      # анимацией, и её длительность — свойство шаблона, а не клиента.
      add :prize_reveal_ms, :integer, null: false, default: 5_000

      add :felt_color, :string, size: 9, null: false, default: "#1F6F4A"
      add :background_color, :string, size: 9, null: false, default: "#10241C"

      add :enabled, :boolean, null: false, default: true
      add :sort_order, :integer, null: false, default: 0
      add :max_rooms, :integer, null: false, default: 100

      timestamps(type: :utc_datetime_usec)
    end

    # Естественный ключ: он же делает `mix sit_n_go.seed` идемпотентным.
    create unique_index(:sit_n_go_settings, [:game_type, :currency, :buy_in, :max_players],
             name: :sit_n_go_settings_natural_key
           )

    create index(:sit_n_go_settings, [:enabled, :sort_order])

    create constraint(:sit_n_go_settings, :sit_n_go_settings_players,
             check: "max_players BETWEEN 2 AND 9"
           )

    create constraint(:sit_n_go_settings, :sit_n_go_settings_amounts,
             check: "buy_in > 0 AND starting_stack > 0"
           )

    # --- Структура уровней -------------------------------------------------

    create table(:sit_n_go_blind_levels, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :sit_n_go_setting_id,
          references(:sit_n_go_settings, type: :binary_id, on_delete: :delete_all),
          null: false

      add :level, :integer, null: false

      # Три номинала, а не два: холдем играется на блайндах, Short Deck —
      # на анте кнопки, где блайндов нет вовсе (`BettingStructure.ButtonAnte`).
      # Что из этого читать, решает структура ставок варианта, поэтому
      # ветвления по виду игры здесь нет — есть три числа в строке.
      add :small_blind, :bigint, null: false, default: 0
      add :big_blind, :bigint, null: false, default: 0
      add :ante, :bigint, null: false, default: 0

      add :duration_seconds, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sit_n_go_blind_levels, [:sit_n_go_setting_id, :level])

    create constraint(:sit_n_go_blind_levels, :sit_n_go_blind_levels_amounts,
             check:
               "level > 0 AND duration_seconds > 0 AND small_blind >= 0 " <>
                 "AND big_blind >= 0 AND ante >= 0 AND (big_blind > 0 OR ante > 0)"
           )

    # --- Призовые тиры -----------------------------------------------------

    create table(:sit_n_go_prize_tiers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :sit_n_go_setting_id,
          references(:sit_n_go_settings, type: :binary_id, on_delete: :delete_all),
          null: false

      # Множитель к взносу в сотых долях: 200 = x2.00, 1_000_000 = x10000.
      # Множитель, а не готовая сумма, — чтобы одна таблица переносилась
      # на любой лимит без пересчёта руками.
      add :multiplier, :bigint, null: false

      # Шанс в миллионных долях: 750_000 = 75%, 1 = 0.0001%. Целое, а не
      # дробь, по тому же правилу, что и деньги: сумма шансов шаблона
      # обязана быть ровно 1_000_000, а float такой суммы не гарантирует.
      add :chance_ppm, :integer, null: false

      # Доли призового фонда по местам в процентах, первым — победитель:
      # [100] или [75, 20, 5]. Список, а не колонки под каждое место,
      # потому что число оплачиваемых мест зависит от тира.
      add :payouts, :json, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sit_n_go_prize_tiers, [:sit_n_go_setting_id, :multiplier])

    create constraint(:sit_n_go_prize_tiers, :sit_n_go_prize_tiers_values,
             check: "multiplier > 0 AND chance_ppm BETWEEN 1 AND 1000000"
           )
  end
end
