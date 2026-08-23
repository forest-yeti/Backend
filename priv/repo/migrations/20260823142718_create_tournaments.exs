defmodule BlockPoker.Repo.Migrations.CreateTournaments do
  use Ecto.Migration

  @moduledoc """
  Турнирный покер: шаблон, структура уровней, сетка выплат, билеты,
  расписание и **инстанс** — конкретный запуск в конкретное время.

  Девять таблиц вместо трёх у Sit & Go, и разделены они по времени жизни,
  а не по удобству. Шаблон вечен и правится оператором; инстанс живёт
  один вечер и обязан пережить рестарт вместе со списком участников,
  фондом и местами. Смешать их в одну строку значило бы либо потерять
  историю прошлых запусков, либо переписывать шаблон каждым турниром.
  """

  def change do
    # Порядок задан внешними ключами, а не разделами постановки: билеты
    # ссылаются на шаблон, сетка выплат — на билеты, погашенный билет —
    # на инстанс, вход — на погашенный билет.
    settings()
    blind_levels()
    tickets()
    payouts()
    schedules()
    instances()
    user_tickets()
    entries()
    seat_snapshots()
  end

  # --- Шаблон --------------------------------------------------------------

  defp settings do
    create table(:tournament_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :name, :string, size: 80
      add :description, :string, size: 500
      add :game_type, :string, null: false
      add :currency, :string, null: false

      # Взнос делится на три части, и это единственное место, где деление
      # задаётся: `buy_in` = призовая часть + `bounty_part`, `entry_fee` —
      # доход рума, в фонд не попадающий. `buy_in = 0` — фриролл.
      add :buy_in, :bigint, null: false
      add :entry_fee, :bigint, null: false, default: 0
      add :starting_stack, :bigint, null: false

      # Сколько сидит за одним столом — это не вместимость турнира.
      # Турнир вместимости в этом смысле не имеет: столов столько, сколько
      # нужно, чтобы рассадить явку.
      add :table_size, :integer, null: false, default: 9

      # Порог старта считается по людям, потолок — тоже: и то и другое
      # про одновременно играющих, а не про число входов.
      add :min_players, :integer, null: false, default: 2
      add :max_players, :integer, null: false

      # Потолок общего числа входов с учётом ре-энтри. `NULL` — без потолка.
      add :max_entries, :integer

      add :rebuy_allowed, :boolean, null: false, default: false
      add :rebuy_cost, :bigint
      add :rebuy_stack, :bigint
      add :max_rebuys, :integer

      add :addon_cost, :bigint, null: false, default: 0
      add :addon_stack, :bigint, null: false, default: 0

      add :guarantee, :bigint, null: false, default: 0

      # `bounty_part = 0` — не баунти-турнир. Прогрессивность и доля
      # убийцы значимы только при ненулевой голове.
      add :bounty_part, :bigint, null: false, default: 0
      add :bounty_progressive, :boolean, null: false, default: true
      add :bounty_split_ppm, :integer, null: false, default: 500_000

      add :registration_opens_before, :integer, null: false, default: 3600
      add :cancel_refund_grace_seconds, :integer, null: false, default: 0

      # Таймеры стола — те же поля, что у кэша и Sit & Go, потому что
      # читает их один и тот же `TableServer`.
      add :action_timeout_ms, :integer, null: false, default: 15_000
      add :time_bank_ms, :integer, null: false, default: 20_000
      add :time_bank_refill, :integer, null: false, default: 5_000
      add :disconnect_grace_ms, :integer, null: false, default: 30_000
      add :button_draw_animation_ms, :integer, null: false, default: 3_000

      # Окно, в котором вылетевший решает, входить ли заново. Пока оно
      # идёт, место не присвоено — вылет ещё не окончателен.
      add :rebuy_prompt_ms, :integer, null: false, default: 30_000

      # Две пары цветов, а не одна: цвет опознаёт не только режим, но и
      # стадию. Финалка перекрашивается в момент, когда турнир схлопнулся
      # до одного стола, — это событие турнира, а не настройка комнаты.
      add :felt_color, :string, size: 9, null: false, default: "#1F4F7A"
      add :background_color, :string, size: 9, null: false, default: "#0B1A2A"
      add :final_felt_color, :string, size: 9, null: false, default: "#6E1F2E"
      add :final_background_color, :string, size: 9, null: false, default: "#1A0A10"

      add :enabled, :boolean, null: false, default: true
      add :sort_order, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :tournament_settings,
             [:name, :game_type, :currency, :buy_in, :table_size],
             name: :tournament_settings_natural_key
           )

    create index(:tournament_settings, [:enabled, :sort_order])

    create constraint(:tournament_settings, :tournament_settings_seats,
             check: "table_size IN (2, 6, 9) AND min_players >= 2 AND max_players >= min_players"
           )

    create constraint(:tournament_settings, :tournament_settings_amounts,
             check:
               "buy_in >= 0 AND entry_fee >= 0 AND starting_stack > 0 AND guarantee >= 0 " <>
                 "AND addon_cost >= 0 AND (addon_cost = 0 OR addon_stack > 0)"
           )

    # Голова берётся из взноса, а не сверх него: `bounty_part > buy_in`
    # означал бы отрицательную призовую часть. Фриролл с баунти невозможен
    # по построению — из нулевого взноса голову взять неоткуда.
    create constraint(:tournament_settings, :tournament_settings_bounty,
             check:
               "bounty_part >= 0 AND bounty_part <= buy_in " <>
                 "AND bounty_split_ppm BETWEEN 0 AND 1000000"
           )

    create constraint(:tournament_settings, :tournament_settings_rebuy,
             check:
               "(rebuy_cost IS NULL OR rebuy_cost >= 0) " <>
                 "AND (rebuy_stack IS NULL OR rebuy_stack > 0) " <>
                 "AND (max_rebuys IS NULL OR max_rebuys >= 0) " <>
                 "AND (max_entries IS NULL OR max_entries >= min_players)"
           )
  end

  # --- Структура уровней ---------------------------------------------------

  defp blind_levels do
    create table(:tournament_blind_levels, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tournament_setting_id,
          references(:tournament_settings, type: :binary_id, on_delete: :delete_all),
          null: false

      add :level, :integer, null: false

      # Три номинала по той же причине, что и в Sit & Go: холдем играется
      # на блайндах, Short Deck — на анте кнопки. Поля `ante_type` нет:
      # анте турнира классическое, с каждого игрока.
      add :small_blind, :bigint, null: false, default: 0
      add :big_blind, :bigint, null: false, default: 0
      add :ante, :bigint, null: false, default: 0

      add :duration_seconds, :integer, null: false

      # «Можно ли ещё войти в этот турнир» — одно правило и для поздней
      # регистрации, и для ре-энтри. Второй источник правды о том же
      # моменте был бы багом.
      add :rebuy_allowed, :boolean, null: false, default: false
      add :addon_allowed, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tournament_blind_levels, [:tournament_setting_id, :level])

    create constraint(:tournament_blind_levels, :tournament_blind_levels_amounts,
             check:
               "level > 0 AND duration_seconds > 0 AND small_blind >= 0 " <>
                 "AND big_blind >= 0 AND ante >= 0 AND (big_blind > 0 OR ante > 0)"
           )
  end

  # --- Сетка выплат --------------------------------------------------------

  defp payouts do
    create table(:tournament_payouts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tournament_setting_id,
          references(:tournament_settings, type: :binary_id, on_delete: :delete_all),
          null: false

      # Строка привязана к интервалу явки и интервалу мест: в MTT явка
      # выясняется только на закрытии регистрации, и фиксированный массив
      # долей на малой явке платил бы три места из четырёх игроков.
      add :entries_from, :integer, null: false
      add :entries_to, :integer

      add :place_from, :integer, null: false
      add :place_to, :integer, null: false

      # Ровно одно из двух: доля фонда на одно место в миллионных либо
      # билет. Смешение строк в пределах диапазона — это и есть саттелит.
      add :share_ppm, :integer

      add :ticket_id, references(:tickets, type: :binary_id, on_delete: :restrict)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:tournament_payouts, [:tournament_setting_id, :entries_from])

    create constraint(:tournament_payouts, :tournament_payouts_ranges,
             check:
               "entries_from >= 2 AND (entries_to IS NULL OR entries_to >= entries_from) " <>
                 "AND place_from >= 1 AND place_to >= place_from AND place_to <= entries_from"
           )

    # Приз — либо деньги, либо билет. Строка с обоими не имеет смысла:
    # непонятно, что именно выдано; строка без обоих — место без приза.
    create constraint(:tournament_payouts, :tournament_payouts_prize,
             check:
               "((share_ppm IS NOT NULL AND ticket_id IS NULL) " <>
                 "OR (share_ppm IS NULL AND ticket_id IS NOT NULL)) " <>
                 "AND (share_ppm IS NULL OR share_ppm BETWEEN 1 AND 1000000)"
           )
  end

  # --- Билеты --------------------------------------------------------------

  defp tickets do
    create table(:tickets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tournament_setting_id,
          references(:tournament_settings, type: :binary_id, on_delete: :restrict),
          null: false

      add :name, :string, size: 80, null: false

      # Дублирует цену шаблона намеренно: цена турнира может вырасти,
      # а уже выданный билет обязан пускать по старой. Иначе оператор
      # одним UPDATE обесценивает выданные призы.
      add :face_value, :bigint, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:tickets, [:tournament_setting_id])

    create constraint(:tickets, :tickets_face_value, check: "face_value >= 0")
  end

  defp user_tickets do
    create table(:user_tickets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :ticket_id, references(:tickets, type: :binary_id, on_delete: :restrict), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      # Строка на экземпляр, а не количество в колонке: у одного игрока
      # может быть несколько одинаковых билетов, а счётчик потребовал бы
      # атомарного декремента и потерял бы историю «откуда и куда».
      add :status, :string, size: 16, null: false, default: "active"
      add :issued_by, :string, size: 64, null: false

      add :used_in_tournament_id,
          references(:tournaments, type: :binary_id, on_delete: :nilify_all)

      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:user_tickets, [:user_id, :status])
    create index(:user_tickets, [:status, :expires_at])

    # Один игрок не может погасить два билета в один турнир. Частичного
    # индекса в MySQL нет, поэтому уникальность строится по паре, а
    # `NULL` в `used_in_tournament_id` её не нарушает: непогашенных
    # билетов у игрока может быть сколько угодно.
    create unique_index(:user_tickets, [:used_in_tournament_id, :user_id],
             name: :user_tickets_one_per_tournament
           )
  end

  # --- Расписание ----------------------------------------------------------

  defp schedules do
    create table(:tournament_schedules, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tournament_setting_id,
          references(:tournament_settings, type: :binary_id, on_delete: :delete_all),
          null: false

      # Местное время рума, без секунд. Пояс задан в конфиге; в UTC оно
      # переводится на конкретную дату, потому что «21:30» — обещание
      # игроку, а не момент времени.
      add :start_time, :time, null: false

      add :weekday, :integer
      add :repeat, :boolean, null: false, default: true
      add :run_on, :date
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create index(:tournament_schedules, [:enabled])

    create constraint(:tournament_schedules, :tournament_schedules_recurrence,
             check:
               "(weekday IS NULL OR weekday BETWEEN 1 AND 7) " <>
                 "AND ((`repeat` = TRUE AND run_on IS NULL) " <>
                 "OR (`repeat` = FALSE AND run_on IS NOT NULL AND weekday IS NULL))"
           )
  end

  # --- Инстанс -------------------------------------------------------------

  defp instances do
    create table(:tournaments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tournament_setting_id,
          references(:tournament_settings, type: :binary_id, on_delete: :restrict),
          null: false

      add :schedule_id,
          references(:tournament_schedules, type: :binary_id, on_delete: :nilify_all)

      add :starts_at, :utc_datetime_usec, null: false
      add :status, :string, size: 20, null: false, default: "announced"

      # Проставляется на старте: конец последнего ребайного уровня.
      add :late_reg_until, :utc_datetime_usec

      # Входы и люди — разные числа, и путать их нельзя: по входам считается
      # фонд и сетка выплат, по людям — порог старта и потолок мест.
      add :entries_count, :integer, null: false, default: 0
      add :players_count, :integer, null: false, default: 0
      add :reentries_count, :integer, null: false, default: 0
      add :addons_count, :integer, null: false, default: 0

      add :prize_pool, :bigint, null: false, default: 0
      add :overlay, :bigint, null: false, default: 0
      add :bounty_pool, :bigint, null: false, default: 0

      # Копия уровней, сетки и цен на момент перехода в `registering`.
      # Дальше шаблон не читается вовсе: правка структуры в БД не должна
      # поднимать блайнды посреди идущего турнира.
      add :snapshot, :json

      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # Тик расписания не должен зависеть от того, сколько раз он сработал.
    create unique_index(:tournaments, [:schedule_id, :starts_at])
    create index(:tournaments, [:status, :starts_at])
    create index(:tournaments, [:tournament_setting_id, :starts_at])

    create constraint(:tournaments, :tournaments_counters,
             check:
               "entries_count >= 0 AND players_count >= 0 AND reentries_count >= 0 " <>
                 "AND addons_count >= 0 AND prize_pool >= 0 AND overlay >= 0 " <>
                 "AND bounty_pool >= 0"
           )
  end

  # --- Входы ---------------------------------------------------------------

  defp entries do
    create table(:tournament_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tournament_id, references(:tournaments, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :restrict), null: false

      # Повторный вход — **новая запись входа**, а не докупка существующей:
      # 50 человек с 20 возвратами дают 70 входов, и сетка выплат считает 70.
      add :entry_number, :integer, null: false, default: 1

      add :status, :string, size: 16, null: false, default: "registered"

      # Текущая цена головы: стартует с `bounty_part` и растёт при PKO.
      # Хранится у входа, а не у игрока: ре-энтри несёт новую голову.
      add :bounty, :bigint, null: false, default: 0

      # Сколько уже выплачено с этой головы убийцам — справочно для
      # инварианта «сумма голов не меняется».
      add :bounty_paid, :bigint, null: false, default: 0

      add :addons_count, :integer, null: false, default: 0

      # Место присваивается только окончательному вылету: пока идёт окно
      # ре-энтри, вылет не окончателен и места нет.
      add :place, :integer
      add :prize, :bigint, null: false, default: 0

      add :paid_with_ticket_id,
          references(:user_tickets, type: :binary_id, on_delete: :nilify_all)

      add :busted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # Каждый вход игрока — своя строка, и повтор того же номера гасится
    # базой: двойной клик по «войти заново» не создаёт второго входа.
    create unique_index(:tournament_entries, [:tournament_id, :user_id, :entry_number])
    create index(:tournament_entries, [:tournament_id, :status])

    create constraint(:tournament_entries, :tournament_entries_values,
             check:
               "entry_number >= 1 AND bounty >= 0 AND bounty_paid >= 0 " <>
                 "AND addons_count >= 0 AND prize >= 0 AND (place IS NULL OR place >= 1)"
           )
  end

  # --- Снапшот рассадки ----------------------------------------------------

  defp seat_snapshots do
    create table(:tournament_seat_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tournament_id, references(:tournaments, type: :binary_id, on_delete: :delete_all),
        null: false

      # Рассадка и стеки — единственное, что не выводится из остальных
      # таблиц. Пишется на каждом завершении раздачи асинхронно, как
      # история раздач: падение `TournamentServer` иначе теряло бы игру.
      add :level, :integer, null: false
      add :hands_played, :integer, null: false, default: 0
      add :seats, :json, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # Снапшот один на турнир и переписывается: прошлые состояния хранит
    # история раздач, а восстанавливаться нужно из последнего.
    create unique_index(:tournament_seat_snapshots, [:tournament_id])
  end
end
