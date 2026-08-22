defmodule Mix.Tasks.Ofc.New do
  @shortdoc "Создаёт стол китайского покера"

  @moduledoc """
  Создание шаблона стола OFC Pineapple.

      mix ofc.new --point-value 10
      mix ofc.new --point-value 100 --currency main --max-players 2
      mix ofc.new --name "Домашний ананас" --point-value 10 --private

  Отдельная команда, а не флаг у `mix cash_game.new`: шаблон живёт в своей
  таблице, и половина флагов кэша — блайнды, анте, рейк, бомб-пот, два
  прогона — к столу без банка неприменима.

  Флаги:

    * `--point-value` — стоимость очка в минимальных единицах; обязателен,
      потому что это и есть лимит стола: банка здесь нет, и других
      номиналов тоже;
    * `--name` — название для лобби (по умолчанию производное от лимита);
    * `--currency` — `main` или `play_money` (по умолчанию `play_money`);
    * `--max-players` — 2 или 3: ананасу нужны 17 карт на игрока, и
      четвёртому колоды уже не хватает (по умолчанию 3);
    * `--buy-in min-max` — границы бай-ина **в очках** (по умолчанию
      `50-200`; `50-` — стол без потолка);
    * `--felt` и `--background` — цвета сукна и фона комнаты (`#RRGGBB`);
    * `--private` — стола нет в общей витрине, вход только по коду; код
      выдаётся сервером и печатается по завершении;
    * `--no-auto-start` — стол не начинает игру сам, первую раздачу
      запускает администратор (см. `mix user.role`);
    * `--dry-run` — показать, что будет создано, и ничего не записывать.

  Приложение о новой строке само не узнаёт: на живой ноде нужен
  `BlockPoker.Tables.Lobby.reload/0` (он же вызывается по таймеру раз в минуту).
  """

  use Mix.Task

  alias BlockPoker.Engine.Ofc
  alias BlockPoker.OfcGames
  alias BlockPoker.OfcGames.OfcSetting

  @requirements ["app.start"]

  @switches [
    name: :string,
    point_value: :integer,
    currency: :string,
    max_players: :integer,
    buy_in: :string,
    felt: :string,
    background: :string,
    private: :boolean,
    auto_start: :boolean,
    dry_run: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _argv} = OptionParser.parse!(argv, strict: @switches)

    attrs = attrs(opts)

    if opts[:dry_run] do
      Mix.shell().info("будет создан: #{describe(attrs)} (ничего не записано)")
    else
      create(attrs, opts[:private] == true)
    end
  end

  defp create(attrs, private?) do
    result =
      if private?,
        do: OfcGames.create_private_setting(attrs),
        else: OfcGames.create_setting(attrs)

    case result do
      {:ok, setting} ->
        Mix.shell().info("создан: #{describe(attrs)}")
        report_code(setting)

      {:error, changeset} ->
        Mix.raise("стол не создан: #{errors(changeset)}")
    end
  end

  defp report_code(%OfcSetting{code: nil}), do: :ok
  defp report_code(%OfcSetting{code: code}), do: Mix.shell().info("код для входа: #{code}")

  defp attrs(opts) do
    {min_buy_in, max_buy_in} = buy_in(opts[:buy_in])

    %{
      name: opts[:name],
      currency: currency(opts[:currency]),
      point_value: point_value(opts[:point_value]),
      max_players: max_players(opts[:max_players]),
      min_buy_in: min_buy_in,
      max_buy_in: max_buy_in,
      felt_color: opts[:felt],
      background_color: opts[:background],
      auto_start: opts[:auto_start] != false
    }
    # Цвета не заданы — остаются дефолты схемы, а не `nil`.
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp point_value(nil), do: Mix.raise("нужна стоимость очка: --point-value 10")

  defp point_value(value) when value > 0, do: value

  defp point_value(_value), do: Mix.raise("стоимость очка должна быть положительной")

  # Сколько игроков сажать, решает дисциплина, а не эта команда: её границы
  # выведены из размера колоды и второй копии иметь не должны.
  defp max_players(nil), do: Ofc.Hand.max_players()

  defp max_players(value) do
    allowed = Ofc.Hand.min_players()..Ofc.Hand.max_players()

    if value in allowed do
      value
    else
      Mix.raise("мест за столом китайского покера может быть #{inspect(Enum.to_list(allowed))}")
    end
  end

  defp currency(nil), do: :play_money

  defp currency(value) do
    case Enum.find(OfcSetting.currencies(), &(Atom.to_string(&1) == value)) do
      nil -> Mix.raise("неизвестная валюта: #{value}")
      currency -> currency
    end
  end

  defp buy_in(nil), do: {50, 200}

  defp buy_in(value) do
    case String.split(value, "-", parts: 2) do
      [min, ""] -> {to_int(min, "--buy-in"), nil}
      [min, max] -> {to_int(min, "--buy-in"), to_int(max, "--buy-in")}
      _other -> Mix.raise("границы бай-ина задаются как min-max: --buy-in 50-200")
    end
  end

  defp to_int(value, flag) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> number
      _other -> Mix.raise("#{flag}: ожидалось целое число, получено #{inspect(value)}")
    end
  end

  defp describe(attrs) do
    name = attrs[:name] || "OFC #{attrs.point_value}"

    "#{name}, очко #{attrs.point_value}, #{attrs.max_players}-max, #{attrs.currency}"
  end

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field}: #{Enum.join(messages, ", ")}" end)
  end
end
