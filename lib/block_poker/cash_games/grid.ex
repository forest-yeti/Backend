defmodule BlockPoker.CashGames.Grid do
  @moduledoc """
  Разворачивает лестницу лимитов из `priv/cash_games/grid.exs` в список
  атрибутов шаблонов и записывает их в БД.

  Логика живёт здесь, а не в `Mix.Task`: задача должна остаться разбором
  аргументов и печатью, а разворачивание сетки — обычный код, который
  тестируется без `mix`.

  Идемпотентность обеспечивается естественным ключом шаблона: существующая
  строка не трогается вовсе, чтобы повторный сид не сбрасывал правки
  оператора. `force: true` перезаписывает — но **не** `enabled`: выключенный
  оператором лимит не должен воскресать от повторного прогона.
  """

  alias BlockPoker.CashGames
  alias BlockPoker.CashGames.CashGameSetting
  alias BlockPoker.Engine.BettingStructure
  alias BlockPoker.Engine.Variant.Registry, as: VariantRegistry

  @grid_path "cash_games/grid.exs"

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
  (`["NL2", "NL10"]`), `:grid` — уже прочитанная структура.
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

  Возвращает `%{created: [...], skipped: [...], updated: [...]}` со строками
  вида `{level, name}` — вызывающему остаётся это напечатать.
  """
  @spec seed([row()], keyword()) :: %{created: list(), skipped: list(), updated: list()}
  def seed(rows, opts \\ []) do
    force? = Keyword.get(opts, :force, false)

    Enum.reduce(rows, %{created: [], skipped: [], updated: []}, fn row, acc ->
      case {CashGames.get_by_natural_key(row.attrs), force?} do
        {nil, _force} ->
          {:ok, setting} = CashGames.create_setting(row.attrs)
          Map.update!(acc, :created, &[setting.name | &1])

        {existing, true} ->
          # `enabled` намеренно не перезаписывается: см. @moduledoc.
          {:ok, setting} = CashGames.update_setting(existing, Map.delete(row.attrs, :enabled))
          Map.update!(acc, :updated, &[setting.name | &1])

        {existing, false} ->
          Map.update!(acc, :skipped, &[CashGameSetting.display_name(existing) | &1])
      end
    end)
    |> Map.new(fn {key, names} -> {key, Enum.reverse(names)} end)
  end

  defp currencies(grid, nil), do: Map.keys(grid.levels) |> Enum.sort()
  defp currencies(_grid, currency), do: [currency]

  defp keep_level?(_level, nil), do: true
  defp keep_level?(level, only), do: level.level in only

  defp game_type(format, grid), do: Map.get(format, :game_type) || grid.defaults.game_type

  defp structure(game_type) do
    game_type |> VariantRegistry.fetch!() |> then(& &1.betting_structure())
  end

  defp attrs(grid, currency, level, format) do
    game_type = game_type(format, grid)
    limits = limits(structure(game_type), level, format)

    grid.defaults
    |> Map.merge(Map.fetch!(grid.visuals, currency))
    |> Map.merge(limits)
    |> Map.merge(%{
      name: "#{level.level} #{format.suffix}",
      game_type: game_type,
      currency: currency,
      max_players: format.max_players,
      sort_order: 0
    })
  end

  # Номиналы уровня в том виде, в каком их принимает структура ставок:
  # блайндовому столу — блайнды, анте-столу — анте и нули вместо блайндов.
  defp limits(BettingStructure.Blinds, level, format) do
    %{
      small_blind: level.small_blind,
      big_blind: level.big_blind,
      ante: ante(format.ante, level.big_blind)
    }
  end

  defp limits(_button_ante, level, format) do
    %{small_blind: 0, big_blind: 0, ante: ante(format.ante, level.big_blind)}
  end

  # Анте типа `big_blind` вносит один игрок, и стандартная сумма — половина
  # большого блайнда. Нечётный bb округляется вниз (NL5: bb 5 -> анте 2).
  #
  # На анте-столе анте равно большому блайнду уровня: лестница лимитов у
  # Short Deck та же, что у холдема, и стол «NL10 Short Deck» стоит игроку
  # столько же, сколько NL10.
  defp ante(:big_blind, big_blind), do: big_blind
  defp ante(:half_big_blind, big_blind), do: div(big_blind, 2)
  defp ante(:none, _big_blind), do: 0
end
