defmodule BlockPoker.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias BlockPoker.Tables.{Lobby, TableRegistry, TableSupervisor}

  @impl true
  def start(_type, _args) do
    children = [
      BlockPoker.Telemetry,
      BlockPoker.Repo,
      {DNSCluster, query: Application.get_env(:block_poker, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: BlockPoker.PubSub},
      Api.RateLimiter,
      {Registry, TableRegistry.child_spec_options()},
      TableSupervisor,
      # Start a worker by calling: BlockPoker.Worker.start_link(arg)
      # {BlockPoker.Worker, arg},
      # Start to serve requests, typically the last entry
      Socket.Endpoint
    ]

    # Лобби поднимается последним и не поднимается в тестах: при старте оно
    # читает шаблоны из БД, а в тестах база живёт под Sandbox и принадлежит
    # тест-процессу. Тесты пула запускают своё лобби явно.
    children = children ++ List.wrap(lobby_child())

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: BlockPoker.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp lobby_child do
    if Application.get_env(:block_poker, :start_lobby, true), do: Lobby
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    Socket.Endpoint.config_change(changed, removed)
    :ok
  end
end
