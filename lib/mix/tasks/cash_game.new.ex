defmodule Mix.Tasks.CashGame.New do
  @shortdoc "Создаёт одну комнату кэш-игры"

  @moduledoc """
  Создание отдельного шаблона кэш-игры — в дополнение к `mix cash_game.seed`,
  который разливает стандартную сетку лимитов.

      mix cash_game.new --blinds 5/10
      mix cash_game.new --name "Домашняя" --blinds 5/10 --max-players 6 \
        --buy-in 40-100 --private --no-auto-start

  Флаги:

    * `--blinds sb/bb` — блайнды, единственный обязательный параметр;
    * `--name` — название для лобби (по умолчанию производное от лимитов);
    * `--game-type` — вариант игры (по умолчанию `texas_holdem`);
    * `--currency` — `main` или `play_money` (по умолчанию `play_money`);
    * `--max-players` — мест за столом, 2..9 (по умолчанию 6);
    * `--buy-in min-max` — границы бай-ина **в больших блайндах**
      (по умолчанию `40-100`; `40-` — стол без потолка);
    * `--ante` — анте в фишках (по умолчанию 0);
    * `--rake` — рейк в сотых долях процента: `450` — это 4.5% (по умолчанию 0);
    * `--private` — комнаты нет в общей сетке лобби, вход только по коду;
      код выдаётся сервером и печатается по завершении;
    * `--no-auto-start` — стол не начинает игру сам, первую раздачу
      запускает администратор (см. `mix user.role`);
    * `--dry-run` — показать, что будет создано, и ничего не записывать.

  Приложение о новой строке само не узнаёт: на живой ноде нужен
  `BlockPoker.Tables.Lobby.reload/0` (он же вызывается по таймеру раз в минуту).
  """

  use Mix.Task

  alias BlockPoker.CashGames
  alias BlockPoker.CashGames.CashGameSetting
  alias BlockPoker.Engine.Variant.Registry, as: VariantRegistry

  @requirements ["app.start"]

  @switches [
    name: :string,
    blinds: :string,
    game_type: :string,
    currency: :string,
    max_players: :integer,
    buy_in: :string,
    ante: :integer,
    rake: :integer,
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
        do: CashGames.create_private_setting(attrs),
        else: CashGames.create_setting(attrs)

    case result do
      {:ok, setting} ->
        Mix.shell().info("создан: #{describe(attrs)}")
        report_code(setting)

      {:error, changeset} ->
        Mix.raise("комната не создана: #{errors(changeset)}")
    end
  end

  defp report_code(%CashGameSetting{code: nil}), do: :ok

  defp report_code(%CashGameSetting{code: code}) do
    Mix.shell().info("код для входа: #{code}")
  end

  defp attrs(opts) do
    {small, big} = blinds(opts[:blinds])
    {min_buy_in, max_buy_in} = buy_in(opts[:buy_in])

    %{
      name: opts[:name],
      game_type: game_type(opts[:game_type]),
      currency: currency(opts[:currency]),
      small_blind: small,
      big_blind: big,
      ante: opts[:ante] || 0,
      max_players: opts[:max_players] || 6,
      min_buy_in: min_buy_in,
      max_buy_in: max_buy_in,
      rake_percent: opts[:rake] || 0,
      auto_start: opts[:auto_start] != false
    }
  end

  defp blinds(nil), do: Mix.raise("не заданы блайнды: --blinds 5/10")

  defp blinds(value) do
    case String.split(value, "/", parts: 2) do
      [small, big] -> {to_int!(small, "малый блайнд"), to_int!(big, "большой блайнд")}
      _other -> Mix.raise("блайнды задаются как sb/bb, например --blinds 5/10")
    end
  end

  defp buy_in(nil), do: {40, 100}

  defp buy_in(value) do
    case String.split(value, "-", parts: 2) do
      [min, ""] -> {to_int!(min, "минимальный бай-ин"), nil}
      [min, max] -> {to_int!(min, "минимальный бай-ин"), to_int!(max, "максимальный бай-ин")}
      _other -> Mix.raise("бай-ин задаётся как min-max в больших блайндах, например 40-100")
    end
  end

  defp game_type(nil), do: :texas_holdem

  defp game_type(value) do
    known = Enum.map(VariantRegistry.ids(), &to_string/1)

    if value in known do
      String.to_existing_atom(value)
    else
      Mix.raise("неизвестный вариант игры: #{value} (известны: #{Enum.join(known, ", ")})")
    end
  end

  defp currency(nil), do: :play_money
  defp currency("main"), do: :main
  defp currency("play_money"), do: :play_money
  defp currency(other), do: Mix.raise("неизвестная валюта: #{other}")

  defp to_int!(value, what) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _other -> Mix.raise("#{what} должен быть целым числом, получено #{inspect(value)}")
    end
  end

  defp describe(attrs) do
    name = attrs.name || "#{attrs.small_blind}/#{attrs.big_blind} #{attrs.max_players}-max"

    "#{name} — #{attrs.currency} #{attrs.small_blind}/#{attrs.big_blind}, " <>
      "мест #{attrs.max_players}, бай-ин #{attrs.min_buy_in}-#{attrs.max_buy_in || "∞"}bb" <>
      if(attrs.auto_start, do: "", else: ", ручной старт")
  end

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field}: #{Enum.join(messages, ", ")}" end)
  end
end
