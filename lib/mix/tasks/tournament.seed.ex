defmodule Mix.Tasks.Tournament.Seed do
  @shortdoc "Разворачивает сетку турниров рума"

  @moduledoc """
  Первичное наполнение `tournament_settings` вместе со структурами
  уровней, сетками выплат и расписанием из `BlockPoker.Tournaments.Grid`.

      mix tournament.seed                       # вся сетка
      mix tournament.seed --only main           # только боевые семейства
      mix tournament.seed --only play_money     # только тестовые
      mix tournament.seed --dry-run             # показать, что будет создано
      mix tournament.seed --reset               # снести прежнюю сетку и залить заново

  Задача идемпотентна: шаблон с тем же естественным ключом
  (`name + game_type + currency + buy_in + table_size`) пропускается.
  Перезаписи нет намеренно — правка шаблона тянет за собой уровни,
  выплаты и расписание, и молча заменять их набор опаснее, чем ничего
  не делать. Для замены есть `--reset`, и он спрашивает подтверждение:
  вместе с шаблонами уезжают их инстансы.

  Планировщик о новых строках узнаёт сам на ближайшем тике: он читает
  расписание каждую минуту, и перезапуск ноды после сида не нужен.
  """

  use Mix.Task

  alias BlockPoker.Tournaments
  alias BlockPoker.Tournaments.Grid

  @requirements ["app.start"]

  @switches [only: :string, dry_run: :boolean, reset: :boolean, force: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _argv} = OptionParser.parse!(argv, strict: @switches)

    rows = Grid.rows(only: only(opts[:only]))

    if opts[:reset], do: reset(opts)

    if opts[:dry_run], do: report_dry_run(rows), else: rows |> Grid.seed() |> report()
  end

  # Снос прежней сетки. Инстансы уезжают вместе с шаблонами, поэтому
  # спрашиваем: на боевой базе это означает отменённые турниры.
  defp reset(opts) do
    if opts[:force] or Mix.shell().yes?("Удалить все турнирные шаблоны вместе с инстансами?") do
      %{settings: settings, tournaments: tournaments} = Tournaments.delete_all_settings()

      Mix.shell().info("удалено шаблонов: #{settings}, инстансов: #{tournaments}\n")
    else
      Mix.raise("отменено")
    end
  end

  defp only(nil), do: nil
  defp only("main"), do: :main
  defp only("play_money"), do: :play_money

  defp only(other) do
    Mix.raise("неизвестный набор: #{other} (ожидалось main или play_money)")
  end

  defp report_dry_run(rows) do
    Enum.each(rows, fn %{attrs: attrs, levels: levels, schedules: schedules} ->
      Mix.shell().info(
        "#{attrs.name}: вход #{attrs.buy_in + attrs.entry_fee}, стек #{attrs.starting_stack}, " <>
          "уровней #{length(levels)}, запусков в сутки #{length(schedules)}"
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
