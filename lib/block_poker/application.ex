defmodule BlockPoker.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias BlockPoker.Admin.Observer, as: AdminObserver
  alias BlockPoker.History.Writer, as: HistoryWriter
  alias BlockPoker.Tables.{Lobby, SitAndGoLobby, TableRegistry, TableSupervisor}
  alias BlockPoker.Tournaments.{TournamentScheduler, TournamentSupervisor}

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
      # Турниры живут в своём супервизоре: падение турнира не должно
      # задевать столы кэша, и наоборот.
      TournamentSupervisor,
      # Фоновые задачи: истечение билетов и отмена недобравших турниров.
      # Возврат денег обязан произойти, даже если нода перезагрузилась
      # между анонсом и стартом, — таймер процесса этого не переживёт,
      # а строка в `oban_jobs` переживёт.
      {Oban, Application.fetch_env!(:block_poker, Oban)},
      # Наблюдение панели: единственный потребитель telemetry-события
      # `[:block_poker, :table, :intent]` и владелец кольцевого буфера
      # ленты. Процесс поднимается всегда, а вот подписку на события
      # заводит только при включённом флаге — выключённый режим не должен
      # стоить ни одного лишнего сообщения (§13 задачи 8).
      AdminObserver,
      # Между столом и Oban обязан стоять отдельный процесс: постановка
      # Oban-задачи — это `Repo.insert`, то есть взятие коннекта из пула
      # синхронно, в вызывающем процессе. Стол делает `cast` и
      # возвращается к игре, коннект ждёт Writer (§6 задачи 6).
      # Start a worker by calling: BlockPoker.Worker.start_link(arg)
      # {BlockPoker.Worker, arg},
      # Start to serve requests, typically the last entry
      Socket.Endpoint
    ]

    # Лобби поднимается последним и не поднимается в тестах: при старте оно
    # читает шаблоны из БД, а в тестах база живёт под Sandbox и принадлежит
    # тест-процессу. Тесты пула запускают своё лобби явно.
    children = children ++ lobby_children() ++ scheduler_children() ++ history_children()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: BlockPoker.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Два пула: кэшевый и турнирный. Они не знают друг о друге и владеют
  # разными комнатами — общее у них только дерево супервизоров и топик,
  # в котором комнаты рассказывают о себе.
  defp lobby_children do
    if Application.get_env(:block_poker, :start_lobby, true) do
      [Lobby, SitAndGoLobby]
    else
      []
    end
  end

  # Планировщик поднимается последним и по тем же причинам, что и лобби:
  # на тике он читает БД, а в тестах она под Sandbox принадлежит
  # тест-процессу. Тесты расписания поднимают его явно и прогоняют тик
  # руками, а не ждут минуту.
  defp scheduler_children do
    if Application.get_env(:block_poker, :start_tournament_scheduler, true) do
      [TournamentScheduler]
    else
      []
    end
  end

  # Между столом и Oban обязан стоять отдельный процесс: постановка
  # Oban-задачи — это `Repo.insert`, то есть взятие коннекта из пула
  # синхронно, в вызывающем процессе. Стол делает `cast` и возвращается
  # к игре, коннект ждёт Writer (§6 задачи 6).
  #
  # В тестах не поднимается по той же причине, что лобби и планировщик:
  # он пишет в БД из своего процесса, а она под Sandbox принадлежит
  # тест-процессу. Тесты истории поднимают его явно.
  defp history_children do
    if Application.get_env(:block_poker, :start_history_writer, true) do
      [HistoryWriter]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    Socket.Endpoint.config_change(changed, removed)
    :ok
  end
end
