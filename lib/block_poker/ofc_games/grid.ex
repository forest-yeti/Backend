defmodule BlockPoker.OfcGames.Grid do
  @moduledoc """
  Разворачивает лестницу лимитов из `priv/ofc_games/grid.exs` в список
  атрибутов шаблонов китайского покера и записывает их в БД.

  Устроено так же, как `BlockPoker.CashGames.Grid`, и по тем же причинам:
  логика живёт здесь, а не в `Mix.Task`, чтобы разворачивание сетки
  тестировалось без `mix`. Общего модуля на две сетки нет намеренно —
  совпадает у них только форма файла, а номинал уровня разный: там блайнды
  и анте, здесь стоимость очка.

  Идемпотентность обеспечивается естественным ключом шаблона
  (`currency + point_value + max_players`): существующая строка не трогается
  вовсе, чтобы повторный сид не сбрасывал правки оператора. `force: true`
  перезаписывает — но **не** `enabled`: выключенный оператором лимит не
  должен воскресать от повторного прогона.
  """

  alias BlockPoker.OfcGames
  alias BlockPoker.OfcGames.OfcSetting

  @grid_path "ofc_games/grid.exs"

  @type row :: %{level: String.t(), attrs: map()}

  @doc "Читает файл сетки. Путь можно переопределить в тестах."
  @spec load(Path.t() | nil) :: map()
  def load(path \\ nil) do
    path = path || Application.app_dir(:block_poker, Path.join("priv", @grid_path))
    {grid, _bindings} = Code.eval_file(path)
    grid
  end

  @doc """
  Разворачивает сетку в список строк шаблонов.

  Опции: `:currency` (`:main` | `:play_money`), `:only` — список уровней
  (`["OFC1", "OFC10"]`), `:grid` — уже прочитанная структура.
  """
  @spec expand(keyword()) :: [row()]
  def expand(opts \\ []) do
    grid = Keyword.get_lazy(opts, :grid, fn -> load(opts[:path]) end)
    currencies = currencies(grid, opts[:currency])
    only = opts[:only]

    for currency <- currencies,
        level <- Map.fetch!(grid.levels, currency),
        keep_level?(level, only),
        format <- grid.formats do
      %{level: level.level, attrs: attrs(grid, currency, level, format)}
    end
    |> Enum.with_index()
    |> Enum.map(fn {row, index} -> put_in(row.attrs.sort_order, index) end)
  end

  @doc """
  Записывает развёрнутую сетку в БД.

  Возвращает `%{created: [...], skipped: [...], updated: [...]}` с именами
  шаблонов — вызывающему остаётся это напечатать.
  """
  @spec seed([row()], keyword()) :: %{created: list(), skipped: list(), updated: list()}
  def seed(rows, opts \\ []) do
    force? = Keyword.get(opts, :force, false)

    Enum.reduce(rows, %{created: [], skipped: [], updated: []}, fn row, acc ->
      case {OfcGames.get_by_natural_key(row.attrs), force?} do
        # Закрытая комната заняла естественный ключ уровня. Сид её не трогает
        # даже под `--force`: превращать чужой стол с кодом в публичный он
        # не вправе, а второй строки на тот же ключ база не даст.
        {%OfcSetting{visibility: :private} = existing, _force} ->
          Map.update!(acc, :skipped, &[OfcSetting.display_name(existing) | &1])

        {nil, _force} ->
          {:ok, setting} = OfcGames.create_setting(row.attrs)
          Map.update!(acc, :created, &[setting.name | &1])

        {existing, true} ->
          # `enabled` намеренно не перезаписывается: см. @moduledoc.
          {:ok, setting} = OfcGames.update_setting(existing, Map.delete(row.attrs, :enabled))
          Map.update!(acc, :updated, &[setting.name | &1])

        {existing, false} ->
          Map.update!(acc, :skipped, &[OfcSetting.display_name(existing) | &1])
      end
    end)
    |> Map.new(fn {key, names} -> {key, Enum.reverse(names)} end)
  end

  defp currencies(grid, nil), do: Map.keys(grid.levels) |> Enum.sort()
  defp currencies(_grid, currency), do: [currency]

  defp keep_level?(_level, nil), do: true
  defp keep_level?(level, only), do: level.level in only

  defp attrs(grid, currency, level, format) do
    grid.defaults
    |> Map.merge(Map.fetch!(grid.visuals, currency))
    |> Map.merge(%{
      name: level.name,
      currency: currency,
      point_value: level.point_value,
      max_players: format.max_players,
      sort_order: 0
    })
  end
end
