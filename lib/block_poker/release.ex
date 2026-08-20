defmodule BlockPoker.Release do
  @moduledoc """
  Операции, которые на проде выполняются без `Mix`.

  В собранном релизе `mix` недоступен, поэтому миграции и первичный сид
  вызываются через `bin/block_poker eval`:

      bin/block_poker eval "BlockPoker.Release.migrate()"
      bin/block_poker eval "BlockPoker.Release.seed_cash_games()"

  Логика не дублируется: сид разворачивает ту же сетку через
  `BlockPoker.CashGames.Grid`, что и `mix cash_game.seed`.
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

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
