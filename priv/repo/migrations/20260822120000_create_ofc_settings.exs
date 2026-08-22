defmodule BlockPoker.Repo.Migrations.CreateOfcSettings do
  use Ecto.Migration

  @moduledoc """
  Шаблон стола китайского покера (OFC Pineapple).

  Своя таблица, а не колонка в `cash_game_settings`: половина полей кэша к
  дисциплине без банка неприменима — блайнды, анте, рейк, бомб-пот, два
  прогона, взнос за вход. Держать их пустыми в каждой OFC-строке значило бы
  заводить в схеме поля, которые никогда не читаются, и полагаться на
  валидацию там, где достаточно отсутствия колонки.

  Стол при этом остаётся кэшем по смыслу: игрок садится со своим стеком и
  встаёт с ним же, деньги ходят через тот же ledger. Отличается расчёт —
  очками вместо банка, — и витрина: OFC-столы в общую сетку кэша не
  подмешиваются, у них свой топик лобби.
  """

  def change do
    create table(:ofc_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :name, :string, size: 80

      # Вид покера нужен ради колоды и росписи пятёрки: ананас играется
      # полной колодой из 52 карт, и Short Deck с ним не сочетается.
      add :game_type, :string, null: false, default: "texas_holdem"
      add :currency, :string, null: false

      # Двое или трое: 3 × 17 = 51 карта из 52, четвёртому уже не хватает.
      add :max_players, :integer, null: false, default: 3

      # Стоимость очка в минимальных единицах. Она же базовая единица стола:
      # по ней считаются границы бай-ина и категория лимита в лобби.
      add :point_value, :bigint, null: false

      # Бай-ин — в базовых единицах стола, как и в кэше.
      add :min_buy_in, :integer, null: false, default: 50
      add :max_buy_in, :integer, null: false, default: 200

      add :action_timeout_ms, :integer, null: false, default: 30_000
      add :time_bank_ms, :integer, null: false, default: 60_000
      add :time_bank_refill, :integer, null: false, default: 15_000
      add :disconnect_grace_ms, :integer, null: false, default: 30_000
      add :sit_out_timeout_ms, :integer, null: false, default: 300_000
      add :rebuy_prompt_ms, :integer, null: false, default: 60_000
      add :button_draw_animation_ms, :integer, null: false, default: 3_000

      add :auto_start, :boolean, null: false, default: true

      add :felt_color, :string, size: 9, null: false, default: "#1F6F4A"
      add :background_color, :string, size: 9, null: false, default: "#10241C"

      add :enabled, :boolean, null: false, default: true
      add :visibility, :string, null: false, default: "public"
      add :code, :string, size: 6
      add :sort_order, :integer, null: false, default: 0
      add :max_rooms, :integer, null: false, default: 100

      timestamps(type: :utc_datetime_usec)
    end

    # Естественный ключ: он же делает сид идемпотентным.
    create unique_index(:ofc_settings, [:currency, :point_value, :max_players],
             name: :ofc_settings_natural_key
           )

    # Код закрытой комнаты уникален среди заданных: `NULL` в MySQL
    # уникальному индексу не мешает.
    create unique_index(:ofc_settings, [:code])
    create index(:ofc_settings, [:enabled, :sort_order])

    create constraint(:ofc_settings, :ofc_settings_players, check: "max_players BETWEEN 2 AND 3")

    # Дисциплина без банка обязана иметь цену очка: иначе раздача считает
    # очки, а фишки не двигаются вовсе.
    create constraint(:ofc_settings, :ofc_settings_point_value, check: "point_value > 0")

    create constraint(:ofc_settings, :ofc_settings_buy_in,
             check: "min_buy_in > 0 AND max_buy_in >= min_buy_in"
           )
  end
end
