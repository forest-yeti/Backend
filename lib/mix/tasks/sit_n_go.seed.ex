defmodule Mix.Tasks.SitNGo.Seed do
  @shortdoc "Разворачивает стандартную сетку гипер-турниров Sit & Go"

  @moduledoc """
  Первичное наполнение `sit_n_go_settings` вместе со структурами уровней
  и таблицами призов из `BlockPoker.SitAndGo.Grid`.

      mix sit_n_go.seed                        # вся сетка плюс тестовые столы
      mix sit_n_go.seed --currency play_money
      mix sit_n_go.seed --game-type short_deck
      mix sit_n_go.seed --max-players 3
      mix sit_n_go.seed --no-test              # без тестовых столов
      mix sit_n_go.seed --dry-run              # показать, что будет создано
      mix sit_n_go.seed --retier               # перезалить таблицы призов

  Задача идемпотентна: шаблон с тем же естественным ключом
  (`game_type + currency + buy_in + max_players`) пропускается. Перезаписи
  нет намеренно — в отличие от кэша, правка шаблона тянет за собой уровни
  и тиры, и молча заменять их набор опаснее, чем ничего не делать.

  `--retier` — единственное исключение, и оно узкое: перезаливаются
  **только таблицы призов** уже заведённых шаблонов. Нужен, когда
  поменялось правило их расчёта (например, появился потолок выплаты):
  обычный прогон такие строки пропустит, потому что шаблоны уже есть.
  Уровни, тайминги и косметику `--retier` не трогает.

  Приложение о правке строк не узнаёт само: после сида на живой ноде нужен
  перечит пула турниров.
  """

  use Mix.Task

  alias BlockPoker.SitAndGo.Grid

  @requirements ["app.start"]

  @switches [
    currency: :string,
    game_type: :string,
    max_players: :integer,
    dry_run: :boolean,
    retier: :boolean,
    test: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _argv} = OptionParser.parse!(argv, strict: @switches)

    rows =
      Grid.expand(
        currency: currency(opts[:currency]),
        game_type: game_type(opts[:game_type]),
        max_players: opts[:max_players]
      ) ++ test_rows(opts)

    cond do
      opts[:dry_run] -> report_dry_run(rows)
      opts[:retier] -> rows |> Grid.retier() |> report_retier()
      true -> rows |> Grid.seed() |> report()
    end
  end

  # Тестовые столы идут в сид по умолчанию: без них джекпотный путь
  # проверить нечем. `--no-test` убирает их там, где витрина должна
  # содержать только боевые лимиты.
  defp test_rows(opts) do
    if Keyword.get(opts, :test, true), do: Grid.test_rows(), else: []
  end

  defp currency(nil), do: nil
  defp currency("main"), do: :main
  defp currency("play_money"), do: :play_money

  defp currency(other) do
    Mix.raise("неизвестная валюта: #{other} (ожидалось main или play_money)")
  end

  defp game_type(nil), do: nil
  defp game_type("texas_holdem"), do: :texas_holdem
  defp game_type("short_deck"), do: :short_deck

  defp game_type(other) do
    Mix.raise("неизвестная дисциплина: #{other} (ожидалось texas_holdem или short_deck)")
  end

  defp report_dry_run(rows) do
    Enum.each(rows, fn %{attrs: attrs, levels: levels, tiers: tiers} ->
      Mix.shell().info(
        "#{attrs.name}: взнос #{attrs.buy_in}, стек #{attrs.starting_stack}, " <>
          "уровней #{length(levels)}, тиров #{length(tiers)}"
      )
    end)

    Mix.shell().info("\nвсего шаблонов: #{length(rows)}")
  end

  defp report_retier(%{updated: updated, missing: missing, failed: failed}) do
    Enum.each(updated, &Mix.shell().info("таблица призов обновлена: #{&1}"))
    Enum.each(missing, &Mix.shell().info("шаблона нет, пропущен: #{&1}"))

    Enum.each(failed, fn {name, reason} ->
      Mix.shell().error("не обновлён: #{name} — #{inspect(reason)}")
    end)

    Mix.shell().info("
обновлено #{length(updated)}, пропущено #{length(missing)}, ошибок #{length(failed)}")

    if failed != [], do: exit({:shutdown, 1})
  end

  defp report(%{created: created, skipped: skipped, failed: failed}) do
    Enum.each(created, &Mix.shell().info("создан: #{&1}"))
    Enum.each(skipped, &Mix.shell().info("пропущен (уже есть): #{&1}"))

    Enum.each(failed, fn {name, reason} ->
      Mix.shell().error("не создан: #{name} — #{inspect(reason)}")
    end)

    Mix.shell().info(
      "\nсоздано #{length(created)}, пропущено #{length(skipped)}, ошибок #{length(failed)}"
    )

    if failed != [], do: exit({:shutdown, 1})
  end
end
