import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :block_poker, BlockPoker.Repo,
  username: "root",
  password: "",
  hostname: "127.127.126.32",
  database: "block-poker_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :block_poker, Socket.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Oe2fLS+hsnDDaugdWfNotSnViEkm/fPSb7KqR8/9vxs+z0aG07dRAXfoUwV68XJh",
  server: false

# Пул комнат в тестах поднимается явно: при старте он читает БД, а она под
# Sandbox принадлежит тест-процессу.
config :block_poker, start_lobby: false

# Планировщик турниров в тестах не тикает сам: он читает БД, а она под
# Sandbox принадлежит тест-процессу. Тесты расписания поднимают его явно
# и прогоняют тик руками, а не ожиданием.
config :block_poker, start_tournament_scheduler: false

# Writer пишет в БД из своего процесса, а она под Sandbox принадлежит
# тест-процессу. Тесты истории поднимают его явно, остальным он не нужен:
# без него `persist_async` — no-op, и игра от этого не меняется ничем.
config :block_poker, start_history_writer: false

# Кэш версий клиента при старте читает БД, а она под Sandbox принадлежит
# тест-процессу. Тесты границ заполняют кэш явно, остальным хватает
# значений из конфигурации.
config :block_poker, start_client_release_cache: false

# Oban в тестах не выполняет джобы фоном: очередь без воркеров означает,
# что джоба доступна для `Oban.Testing`, но не стартует сама и не лезет
# в чужую транзакцию.
config :block_poker, Oban, testing: :manual

# Наблюдение панели в тестах включено: иначе тесты god-mode проверяли бы
# только то, что он выключен. В проде флаг остаётся выключенным (§13
# задачи 8), и это проверяется отдельным тестом на дефолт конфига.
config :block_poker, :admin_observer, enabled: true

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Процессы турниров в тестах поднимает сам тест: ему нужны инжектированные
# часы и доступ к песочнице БД, а регистрация в контексте про это не знает.
config :block_poker, :tournament_autostart, false

# Баннеры: картинки пишутся во временный каталог сборки, а не в `priv/`.
# Тесты кладут файлы на диск по-настоящему — проверять разбор картинки на
# моке файловой системы значит проверять мок.
config :block_poker, :banners,
  dir: Path.expand("../tmp/banners", __DIR__),
  base_url: "http://localhost/banners"

config :block_poker, :sounds,
  dir: Path.expand("../tmp/sounds", __DIR__),
  base_url: "http://localhost/sounds"
