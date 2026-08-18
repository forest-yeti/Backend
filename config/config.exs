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
