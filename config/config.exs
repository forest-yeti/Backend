# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :block_poker,
  ecto_repos: [BlockPoker.Repo],
  generators: [timestamp_type: :utc_datetime_usec, binary_id: true]

# Configure the endpoint
config :block_poker, Socket.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: Api.ErrorJSON],
    layout: false
  ],
  pubsub_server: BlockPoker.PubSub

# Часовой пояс рума. Расписание турниров ведётся в нём («каждый день
# в 21:30»), а в БД и в протокол уходит UTC. Пояс, а не готовый сдвиг,
# потому что «21:30» — это обещание игроку, а не момент времени: при
# переходе на летнее время турнир обязан остаться в 21:30 по его часам.
config :block_poker, :room_timezone, "Europe/Moscow"

# Автообновление клиента (задача 34). Значения по умолчанию намеренно
# «пропускают всех»: `minimum: "0.0.0"` не отсекает ни одну сборку, включая
# те, что про `client_vsn` ещё не знают. Реальные границы приходят из
# окружения — их поднимают без передеплоя кода.
config :block_poker, :client_release,
  current: "0.0.0",
  minimum: "0.0.0",
  feed_url: nil,
  dir: nil

# Баннеры. Каталог не настроен — картинки через панель не грузятся, а
# уже сохранённые адреса продолжают работать: раздавать файлы может
# nginx или CDN, и бэкенд об этом знать не обязан.
config :block_poker, :banners, dir: nil, base_url: nil

# Звуки администрации — та же схема, что и у баннеров.
config :block_poker, :sounds, dir: nil, base_url: nil

# База часовых поясов. `tz` компилирует данные IANA в модули на сборке:
# в рантайме нет ни сетевых загрузок, ни фонового процесса обновления.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Фоновые задачи: истечение билетов, отмена недобравших турниров, выплаты.
# Очереди разведены по цене ошибки — деньги не должны стоять в очереди
# за уборкой просроченных купонов.
config :block_poker, Oban,
  repo: BlockPoker.Repo,
  # MySQL, а не Postgres: движок `Dolphin` и оповещение через `PG` вместо
  # `LISTEN/NOTIFY`, которого в MySQL нет. Лидерство — через таблицу
  # `oban_peers`, по той же причине.
  engine: Oban.Engines.Dolphin,
  notifier: Oban.Notifiers.PG,
  peer: Oban.Peers.Database,
  queues: [tournaments: 10, tickets: 5, history: 20],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron,
     crontab: [
       {"*/10 * * * *", BlockPoker.Tournaments.Workers.ExpireTickets},
       # Чистка раздач — раз в сутки и ночью: удаление идёт пачками и
       # соревнуется за те же таблицы, в которые пишется живая игра.
       {"20 4 * * *", BlockPoker.History.Workers.Prune}
     ]}
  ]

# Наблюдение за столами из панели администратора (god-mode).
#
# По умолчанию **выключено**, и это не перестраховка: режим отдаёт все
# карманные карты всех игроков в реальном времени, то есть компрометация
# админского доступа при включённом флаге равна компрометации всех игр
# разом. В проде он не включается ни разу до тех пор, пока это сознательно
# не сделано, а перед публичным релизом вырезается целиком (§13 задачи 8).
config :block_poker, :admin_observer, enabled: false

# Origin'ы, с которых пускается панель. Панель — отдельное приложение на
# другом адресе, поэтому CORS настраивается явно списком; `*` не
# поддерживается вовсе (§8 задачи 8).
config :block_poker, :admin_origins, []

# Сколько дней живут раздачи. Агрегаты и турнирные результаты не чистятся
# никогда, поэтому срок относится только к `hands` и `ofc_hands`.
config :block_poker, :history_retention_days, 90

# Контекст подписи токенов (`Phoenix.Token`). Вынесен в конфиг, чтобы ядро
# не зависело от транспорта на этапе компиляции.
config :block_poker, :token_context, Socket.Endpoint

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
