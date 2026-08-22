defmodule Mix.Tasks.Ofc.Seed do
  @shortdoc "Разворачивает стандартную сетку лимитов китайского покера"

  @moduledoc """
  Первичное наполнение `ofc_settings` из `priv/ofc_games/grid.exs`.

      mix ofc.seed                        # обе валюты целиком
      mix ofc.seed --currency play_money
      mix ofc.seed --only OFC1,OFC5
      mix ofc.seed --dry-run              # показать, что будет создано
      mix ofc.seed --force                # перезаписать существующие

  Задача идемпотентна: существующая строка (естественный ключ —
  `currency + point_value + max_players`) пропускается, чтобы повторный
  прогон не сбрасывал правки оператора. `--force` перезаписывает всё,
  кроме `enabled`.

  Приложение не узнаёт о правке строк само — после сида на живой ноде нужен
  `BlockPoker.Tables.Lobby.reload/0` (он же вызывается по таймеру раз в минуту).
  """

  use Mix.Task

  alias BlockPoker.OfcGames.Grid

  @requirements ["app.start"]

  @switches [currency: :string, only: :string, dry_run: :boolean, force: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _argv} = OptionParser.parse!(argv, strict: @switches)

    rows = Grid.expand(currency: currency(opts[:currency]), only: only(opts[:only]))

    if opts[:dry_run] do
      report_dry_run(rows)
    else
      rows |> Grid.seed(force: opts[:force] || false) |> report()
    end
  end

  defp currency(nil), do: nil
  defp currency("main"), do: :main
  defp currency("play_money"), do: :play_money

  defp currency(other) do
    Mix.raise("неизвестная валюта: #{other} (ожидалось main или play_money)")
  end

  defp only(nil), do: nil
  defp only(list), do: String.split(list, ",", trim: true) |> Enum.map(&String.trim/1)

  defp report_dry_run(rows) do
    Enum.each(rows, fn row ->
      attrs = row.attrs

      Mix.shell().info(
        "#{attrs.name}: #{attrs.currency} очко #{attrs.point_value}, " <>
          "вход #{attrs.min_buy_in} очков, мест #{attrs.max_players}"
      )
    end)

    Mix.shell().info("итого: #{length(rows)} шаблонов (ничего не записано)")
  end

  defp report(%{created: created, updated: updated, skipped: skipped}) do
    Enum.each(created, &Mix.shell().info("создан:   #{&1}"))
    Enum.each(updated, &Mix.shell().info("обновлён: #{&1}"))

    Mix.shell().info(
      "создано #{length(created)}, обновлено #{length(updated)}, " <>
        "пропущено как существующие #{length(skipped)}"
    )
  end
end
