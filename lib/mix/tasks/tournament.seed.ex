defmodule Mix.Tasks.Tournament.Seed do
  @shortdoc "Разворачивает стандартную сетку турниров"

  @moduledoc """
  Первичное наполнение `tournament_settings` вместе со структурами
  уровней, сетками выплат и расписанием из `BlockPoker.Tournaments.Grid`.

      mix tournament.seed                       # вся сетка
      mix tournament.seed --currency play_money
      mix tournament.seed --speed turbo
      mix tournament.seed --game-type short_deck
      mix tournament.seed --dry-run             # показать, что будет создано

  Задача идемпотентна: шаблон с тем же естественным ключом
  (`name + game_type + currency + buy_in + table_size`) пропускается.
  Перезаписи нет намеренно — правка шаблона тянет за собой уровни,
  выплаты и расписание, и молча заменять их набор опаснее, чем ничего
  не делать.

  Планировщик о новых строках узнаёт сам на ближайшем тике: он читает
  расписание каждую минуту, и перезапуск ноды после сида не нужен.
  """

  use Mix.Task

  alias BlockPoker.Tournaments.Grid

  @requirements ["app.start"]

  @switches [
    currency: :string,
    speed: :string,
    game_type: :string,
    dry_run: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _argv} = OptionParser.parse!(argv, strict: @switches)

    rows =
      Grid.rows(
        currency: currency(opts[:currency]),
        speed: speed(opts[:speed]),
        game_type: game_type(opts[:game_type])
      )

    if opts[:dry_run], do: report_dry_run(rows), else: rows |> Grid.seed() |> report()
  end

  defp currency(nil), do: nil
  defp currency("main"), do: :main
  defp currency("play_money"), do: :play_money

  defp currency(other) do
    Mix.raise("неизвестная валюта: #{other} (ожидалось main или play_money)")
  end

  defp speed(nil), do: nil
  defp speed("regular"), do: :regular
  defp speed("turbo"), do: :turbo
  defp speed("hyper"), do: :hyper

  defp speed(other) do
    Mix.raise("неизвестная скорость: #{other} (ожидалось regular, turbo или hyper)")
  end

  defp game_type(nil), do: nil
  defp game_type("texas_holdem"), do: :texas_holdem
  defp game_type("short_deck"), do: :short_deck

  defp game_type(other) do
    Mix.raise("неизвестная дисциплина: #{other} (ожидалось texas_holdem или short_deck)")
  end

  defp report_dry_run(rows) do
    Enum.each(rows, fn %{attrs: attrs, levels: levels, payouts: payouts} ->
      Mix.shell().info(
        "#{attrs.name}: вход #{attrs.buy_in + attrs.entry_fee}, стек #{attrs.starting_stack}, " <>
          "уровней #{length(levels)}, строк выплат #{length(payouts)}"
      )
    end)

    Mix.shell().info("\nвсего шаблонов: #{length(rows)}")
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
