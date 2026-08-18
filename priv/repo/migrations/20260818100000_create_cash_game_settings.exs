defmodule BlockPoker.Repo.Migrations.CreateCashGameSettings do
  use Ecto.Migration

  def change do
    create table(:cash_game_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :name, :string, size: 80
      add :game_type, :string, null: false
      add :currency, :string, null: false

      add :small_blind, :bigint, null: false
      add :big_blind, :bigint, null: false
      add :ante, :bigint, null: false, default: 0
      add :ante_type, :string, null: false, default: "big_blind"
      add :max_players, :integer, null: false

      # Бай-ин хранится в больших блайндах: запись переживает смену лимитов.
      add :min_buy_in, :integer, null: false, default: 40
      add :max_buy_in, :integer

      add :rake_percent, :integer, null: false, default: 0
      add :rake_cap_by_players, :json
      add :no_flop_no_drop, :boolean, null: false, default: true

      add :action_timeout_ms, :integer, null: false, default: 20_000
      add :time_bank_ms, :integer, null: false, default: 30_000
      add :time_bank_refill, :integer, null: false, default: 10_000
      add :disconnect_grace_ms, :integer, null: false, default: 30_000
      add :sit_out_max_hands, :integer, null: false, default: 20
      add :rebuy_prompt_ms, :integer, null: false, default: 60_000
      add :button_draw_animation_ms, :integer, null: false, default: 3_000

      add :allow_post_blind, :boolean, null: false, default: true
      add :blind_dodge_window_hands, :integer, null: false, default: 10

      add :felt_color, :string, size: 9, null: false, default: "#1F6F4A"
      add :background_color, :string, size: 9, null: false, default: "#10241C"

      add :enabled, :boolean, null: false, default: true
      add :visibility, :string, null: false, default: "public"
      add :sort_order, :integer, null: false, default: 0
      add :max_rooms, :integer, null: false, default: 100

      timestamps(type: :utc_datetime_usec)
    end

    # Естественный ключ шаблона: он же делает `mix cash_game.seed` идемпотентным.
    create unique_index(
             :cash_game_settings,
             [:game_type, :currency, :small_blind, :big_blind, :ante, :max_players],
             name: :cash_game_settings_natural_key
           )

    create index(:cash_game_settings, [:enabled, :sort_order])

    create constraint(:cash_game_settings, :cash_game_settings_blinds,
             check: "big_blind > small_blind AND small_blind > 0 AND ante >= 0"
           )

    create constraint(:cash_game_settings, :cash_game_settings_max_players,
             check: "max_players BETWEEN 2 AND 9"
           )

    create constraint(:cash_game_settings, :cash_game_settings_buy_in,
             check: "min_buy_in >= 20 AND (max_buy_in IS NULL OR max_buy_in >= min_buy_in)"
           )

    create constraint(:cash_game_settings, :cash_game_settings_rake,
             check: "rake_percent BETWEEN 0 AND 1000"
           )
  end
end
