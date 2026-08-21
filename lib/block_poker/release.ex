defmodule BlockPoker.Release do
  @moduledoc """
  Операции, которые на проде выполняются без `Mix`.

  В собранном релизе `mix` недоступен, поэтому миграции и первичный сид
  вызываются через `bin/block_poker eval`:

      bin/block_poker eval "BlockPoker.Release.migrate()"
      bin/block_poker eval "BlockPoker.Release.seed_cash_games()"
      bin/block_poker eval "BlockPoker.Release.seed_sit_n_go()"

  Логика не дублируется: сид разворачивает те же сетки через
  `BlockPoker.CashGames.Grid` и `BlockPoker.SitAndGo.Grid`, что и
  одноимённые mix-задачи.
  """

  @app :block_poker

  @doc "Накатывает все непринятые миграции."
  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc "Откатывает репозиторий до указанной версии."
  @spec rollback(module(), integer()) :: :ok
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    :ok
  end

  @doc """
  Разворачивает сетку лимитов кэш-игры в `cash_game_settings`.

  Опции те же, что у `mix cash_game.seed`: `:currency`, `:only`, `:force`.
  Идемпотентно — существующие шаблоны не трогаются без `force: true`.
  """
  @spec seed_cash_games(keyword()) :: %{created: list(), skipped: list(), updated: list()}
  def seed_cash_games(opts \\ []) do
    load_app()
    {expand_opts, seed_opts} = Keyword.split(opts, [:currency, :only, :path, :grid])

    {:ok, result, _} =
      Ecto.Migrator.with_repo(BlockPoker.Repo, fn _repo ->
        expand_opts
        |> BlockPoker.CashGames.Grid.expand()
        |> BlockPoker.CashGames.Grid.seed(seed_opts)
      end)

    result
  end

  @doc """
  Разворачивает сетку гипер-турниров в `sit_n_go_settings` вместе с их
  структурами уровней и таблицами призов.

  Идемпотентно: шаблон с тем же естественным ключом пропускается.
  `test: false` убирает тестовые столы с завышенным джекпотом — на боевой
  витрине им не место, но по умолчанию они ставятся, чтобы джекпотный путь
  было чем проверить.
  """
  @spec seed_sit_n_go(keyword()) :: %{created: list(), skipped: list(), failed: list()}
  def seed_sit_n_go(opts \\ []) do
    load_app()

    {:ok, result, _} =
      Ecto.Migrator.with_repo(BlockPoker.Repo, fn _repo ->
        opts |> sit_n_go_rows() |> BlockPoker.SitAndGo.Grid.seed()
      end)

    result
  end

  @doc """
  Перезаливает таблицы призов уже заведённых турнирных шаблонов.

  Нужна, когда поменялось правило их расчёта: обычный сид такие строки
  пропускает, потому что шаблоны уже есть. Уровни, тайминги и косметику
  не трогает.
  """
  @spec retier_sit_n_go(keyword()) :: %{updated: list(), missing: list(), failed: list()}
  def retier_sit_n_go(opts \\ []) do
    load_app()

    {:ok, result, _} =
      Ecto.Migrator.with_repo(BlockPoker.Repo, fn _repo ->
        opts |> sit_n_go_rows() |> BlockPoker.SitAndGo.Grid.retier()
      end)

    result
  end

  defp sit_n_go_rows(opts) do
    {expand_opts, opts} = Keyword.split(opts, [:currency, :game_type, :max_players])
    rows = BlockPoker.SitAndGo.Grid.expand(expand_opts)

    if Keyword.get(opts, :test, true) do
      rows ++ BlockPoker.SitAndGo.Grid.test_rows()
    else
      rows
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
