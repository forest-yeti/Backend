defmodule BlockPoker.Repo.Migrations.CreateHistory do
  use Ecto.Migration

  @moduledoc """
  История раздач и статистика игрока (задача 6).

  Семь таблиц, разделённых по трём осям.

  **Дисциплина.** Холдем (кэш, Sit & Go, MTT) играет улицы, банк и
  вскрытие — `hands` / `hand_players` / `hand_actions`. Китайский покер
  не играет ничего из этого: у него нет банка, улиц и борда, зато есть
  раскладка, роялти и попарный счёт — `ofc_hands` / `ofc_hand_players`.
  Одна таблица на обе дисциплины дала бы строку, у которой половина
  колонок всегда `NULL`.

  **Время жизни.** Раздачи живут 90 дней и чистятся джобом; агрегаты
  (`player_stats_daily`) и турнирные результаты (`tournament_results`)
  не чистятся никогда. Поэтому агрегат считается инкрементально по концу
  каждой раздачи, а не свёрткой перед удалением: свёртка ломается ровно
  один раз, и восстановить её будет уже неоткуда.

  **Владелец.** `tournament_results` — снапшот истории, а не чтение из
  `tournament_entries`: рабочая таблица живого турнира принадлежит
  контексту `Tournaments` и будет меняться вместе с механикой.
  """

  def change do
    hands()
    hand_players()
    hand_actions()
    ofc_hands()
    ofc_hand_players()
    player_stats_daily()
    tournament_results()
  end

  defp hands do
    create table(:hands, primary_key: false) do
      # PK генерируется в момент **старта** раздачи, а не записи: на нём
      # держится идемпотентность повторной Oban-задачи.
      add :id, :binary_id, primary_key: true

      # Комната живёт в памяти и внешним ключом быть не может.
      add :room_id, :binary_id, null: false

      add :game_mode, :string, null: false
      add :setting_id, :binary_id
      add :tournament_id, :binary_id
      add :level_number, :integer
      add :hand_number, :integer, null: false, default: 0
      add :variant, :string, null: false

      add :button_seat, :integer
      add :bet_unit, :bigint, null: false, default: 0
      add :small_blind, :bigint, null: false, default: 0
      add :big_blind, :bigint, null: false, default: 0
      add :ante, :bigint, null: false, default: 0

      add :board, :json
      add :board_2, :json
      add :bomb_pot, :bigint

      add :pot, :bigint, null: false, default: 0
      add :rake, :bigint, null: false, default: 0
      add :pots, :json

      add :started_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # Чистка идёт по возрасту раздачи, поэтому индекс по нему отдельный.
    create index(:hands, [:ended_at])
    create index(:hands, [:room_id, :ended_at])
    create index(:hands, [:tournament_id, :hand_number])
  end

  defp hand_players do
    create table(:hand_players, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :hand_id, references(:hands, type: :binary_id, on_delete: :delete_all), null: false

      # Удаление аккаунта не стирает чужую историю: раздача общая для
      # всех, кто сидел за столом, и вычёркивать из неё игрока значило бы
      # ломать её остальным.
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      add :seat, :integer, null: false
      add :position, :string

      add :starting_stack, :bigint, null: false, default: 0
      add :hole_cards, :json
      add :card_visibility, :string, null: false, default: "hidden"

      add :invested, :bigint, null: false, default: 0
      add :won, :bigint, null: false, default: 0
      add :net, :bigint, null: false, default: 0
      add :ev_amount, :bigint

      add :status, :string, null: false
      add :rank, :json

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:hand_players, [:user_id, :hand_id])
    # Основная выборка истории: своя лента по времени.
    create index(:hand_players, [:user_id, :inserted_at])
  end

  defp hand_actions do
    create table(:hand_actions, primary_key: false) do
      add :hand_id, references(:hands, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :seq, :integer, primary_key: true

      add :street, :string, null: false
      add :seat, :integer, null: false
      add :action, :string, null: false

      add :amount, :bigint, null: false, default: 0
      add :to_amount, :bigint, null: false, default: 0
      add :pot_before, :bigint, null: false, default: 0
      add :stack_after, :bigint, null: false, default: 0

      add :elapsed_ms, :integer, null: false, default: 0
      add :auto, :boolean, null: false, default: false
    end
  end

  defp ofc_hands do
    create table(:ofc_hands, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :room_id, :binary_id, null: false
      add :game_mode, :string, null: false
      add :setting_id, :binary_id
      add :hand_number, :integer, null: false, default: 0
      add :variant, :string, null: false

      add :button_seat, :integer
      add :point_value, :bigint, null: false, default: 0

      add :started_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ofc_hands, [:ended_at])
    create index(:ofc_hands, [:room_id, :ended_at])
  end

  defp ofc_hand_players do
    create table(:ofc_hand_players, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :ofc_hand_id, references(:ofc_hands, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      add :seat, :integer, null: false

      add :box, :json

      # Сбросы пишутся для всех, но наружу уходят только своему владельцу:
      # за столом их не видит никто.
      add :discards, :json

      add :foul, :boolean, null: false, default: false
      add :royalties, :json
      add :royalty_total, :integer, null: false, default: 0

      add :fantasy, :boolean, null: false, default: false
      add :fantasy_next, :boolean, null: false, default: false
      add :fantasy_cards, :integer

      add :points, :integer, null: false, default: 0
      add :net, :bigint, null: false, default: 0
      add :scoop_count, :integer, null: false, default: 0
      add :line_results, :json

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:ofc_hand_players, [:user_id, :ofc_hand_id])
    create index(:ofc_hand_players, [:user_id, :inserted_at])
  end

  defp player_stats_daily do
    create table(:player_stats_daily, primary_key: false) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :day, :date, primary_key: true
      add :game_mode, :string, primary_key: true

      # Разрез по лимиту. В PK участвовать обязан, а `NULL` в MySQL не
      # сравним сам с собой — поэтому пустой разрез хранится нулевым
      # UUID, а не `NULL`.
      add :setting_id, :binary_id, primary_key: true

      # Счётчики `Engine.Stats`: числители и знаменатели раздельно —
      # проценты не складываются, а агрегат обязан суммироваться по
      # любому набору дней.
      add :hands, :bigint, null: false, default: 0
      add :vpip, :bigint, null: false, default: 0
      add :pfr, :bigint, null: false, default: 0
      add :three_bet_chances, :bigint, null: false, default: 0
      add :three_bets, :bigint, null: false, default: 0
      add :saw_flop, :bigint, null: false, default: 0
      add :showdowns, :bigint, null: false, default: 0
      add :aggressive, :bigint, null: false, default: 0
      add :calls, :bigint, null: false, default: 0

      # Единица `net` зависит от режима: в кэше и OFC это деньги, в
      # турнире — турнирные фишки. Складывать строки разных режимов
      # нечем, поэтому `game_mode` входит в первичный ключ.
      add :net, :bigint, null: false, default: 0
      add :invested, :bigint, null: false, default: 0
      add :won, :bigint, null: false, default: 0
      add :rake_paid, :bigint, null: false, default: 0
      add :ev_net, :bigint, null: false, default: 0
      add :bb_sum, :bigint, null: false, default: 0

      add :ofc_points, :bigint, null: false, default: 0
      add :fantasy_entries, :bigint, null: false, default: 0
      add :fantasy_holds, :bigint, null: false, default: 0
      add :fantasy_hands, :bigint, null: false, default: 0
      add :fouls, :bigint, null: false, default: 0
      add :scoops, :bigint, null: false, default: 0
      add :royalty_top, :bigint, null: false, default: 0
      add :royalty_middle, :bigint, null: false, default: 0
      add :royalty_bottom, :bigint, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:player_stats_daily, [:user_id, :day])
  end

  defp tournament_results do
    create table(:tournament_results, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Строка на **вход**, а не на игрока: три ре-энтри — три строки.
      # Unique здесь и есть идемпотентность записи при вылете.
      add :entry_id, :binary_id, null: false

      add :tournament_id, :binary_id, null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :title, :string, size: 120
      add :tournament_setting_id, :binary_id
      add :format, :string, null: false
      add :bounty, :boolean, null: false, default: false

      add :entry_kind, :string, null: false, default: "initial"
      add :entry_index, :integer, null: false, default: 0

      add :buy_in, :bigint, null: false, default: 0
      add :entry_fee, :bigint, null: false, default: 0
      add :addons_count, :integer, null: false, default: 0
      add :addons_cost, :bigint, null: false, default: 0

      add :prize, :bigint, null: false, default: 0
      add :bounty_paid, :bigint, null: false, default: 0

      # Справочно: собственная невыплаченная голова — не полученные
      # деньги, и в ROI она не входит.
      add :bounty_final, :bigint, null: false, default: 0
      add :refund, :bigint, null: false, default: 0

      add :place, :integer
      add :entrants, :integer
      add :itm, :boolean, null: false, default: false
      add :outcome, :string, null: false

      add :hands_played, :integer, null: false, default: 0

      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tournament_results, [:entry_id])
    create index(:tournament_results, [:user_id, :finished_at])
    create index(:tournament_results, [:tournament_id])
  end
end
