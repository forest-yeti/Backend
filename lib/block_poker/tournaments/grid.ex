defmodule BlockPoker.Tournaments.Grid do
  @moduledoc """
  Стандартная сетка турниров рума: шаблоны, структуры уровней, выплаты
  и расписание.

  Живёт в коде, а не в SQL-файле, по той же причине, что и сетка Sit & Go:
  экономика турнира — это свойство набора строк, и её нужно уметь
  проверить тестом. Сид только раскладывает посчитанное по таблицам.

  ## Что задаёт сетку

  Три оси: **валюта**, **цена входа** и **скорость**. Скорость — это
  длительность уровня и стартовый стек в больших блайндах: турбо играет
  вдвое быстрее обычного и потому даёт меньше игры за те же деньги.

  Число оплачиваемых мест выводится из явки, а не задаётся руками:
  сетка выплат описана долями по диапазонам, и на семи участниках платят
  одно место, а на трёхстах — сорок.

  ## Правило выплат

  Доли внутри диапазона обязаны складываться ровно в миллион, не
  возрастать с местом и не оплачивать мест больше, чем входов в этом
  диапазоне. Всё это проверяет `Engine.TournamentPayout.validate/3`,
  и оно же падает в CI, если правку сетки сделали неаккуратно.
  """

  alias BlockPoker.Tournaments

  @doc """
  Структура уровней.

  Три семейства, и различаются они только длительностью уровня:
  обычный турнир — десять минут, турбо — пять, гипер — три. Номиналы
  одни и те же: скорость турнира задаётся тем, как быстро стек тает
  относительно блайндов, а не самими блайндами.

  Ребайные уровни — первые четыре: поздняя регистрация и ре-энтри живут
  ровно столько, сколько стартовый стек остаётся игровым. Аддон — на
  последнем ребайном.
  """
  @spec blind_levels(atom()) :: [map()]
  def blind_levels(speed) do
    duration = duration_of(speed)

    [
      {25, 50, 0},
      {50, 100, 0},
      {75, 150, 25},
      {100, 200, 25},
      {150, 300, 50},
      {200, 400, 50},
      {300, 600, 75},
      {400, 800, 100},
      {600, 1200, 150},
      {800, 1600, 200},
      {1200, 2400, 300},
      {1600, 3200, 400},
      {2400, 4800, 600},
      {3200, 6400, 800},
      {5000, 10_000, 1000}
    ]
    |> Enum.with_index(1)
    |> Enum.map(fn {{small, big, ante}, level} ->
      %{
        level: level,
        small_blind: small,
        big_blind: big,
        ante: ante,
        duration_seconds: duration,
        # Вход открыт, пока стартовый стек остаётся игровым: к пятому
        # уровню он перестаёт им быть, и поздняя регистрация теряет смысл.
        rebuy_allowed: level <= 4,
        # Аддон берётся на перерыве внутри последнего ребайного уровня —
        # на пересечении двух правил, а не на своём поле.
        addon_allowed: level == 4
      }
    end)
  end

  defp duration_of(:hyper), do: 180
  defp duration_of(:turbo), do: 300
  defp duration_of(_regular), do: 600

  @doc """
  Сетка выплат: доли по диапазонам явки.

  Четыре диапазона, и логика их та же, что у любого рума: чем больше
  явка, тем больше мест оплачивается и тем меньше доля первого.

  * `2..9` — платим два места. Меньше нельзя: турнир на двоих, где
    оплачено одно, — это фризаут хедз-ап, и он законен;
  * `10..29` — три места;
  * `30..99` — шесть;
  * `100+` — восемнадцать.

  Доли подобраны так, чтобы каждая строка складывалась ровно в миллион
  и не возрастала с местом. Проверяет это не комментарий, а
  `Engine.TournamentPayout.validate/3` в тесте сетки.
  """
  @spec payouts() :: [map()]
  def payouts do
    [
      band(2, 9, [{1, 1, 650_000}, {2, 2, 350_000}]),
      band(10, 29, [{1, 1, 500_000}, {2, 2, 300_000}, {3, 3, 200_000}]),
      band(30, 99, [
        {1, 1, 350_000},
        {2, 2, 220_000},
        {3, 3, 150_000},
        {4, 4, 110_000},
        {5, 6, 85_000}
      ]),
      band(100, nil, [
        {1, 1, 224_000},
        {2, 2, 150_000},
        {3, 3, 105_000},
        {4, 4, 80_000},
        {5, 6, 60_000},
        {7, 9, 40_000},
        {10, 12, 27_000},
        {13, 18, 20_000}
      ])
    ]
    |> List.flatten()
  end

  defp band(from, to, rows) do
    Enum.map(rows, fn {place_from, place_to, share_ppm} ->
      %{
        entries_from: from,
        entries_to: to,
        place_from: place_from,
        place_to: place_to,
        share_ppm: share_ppm
      }
    end)
  end

  @doc """
  Шаблоны стандартной сетки.

  Цены — в минимальных единицах: `1100` это доллар взноса и десять
  центов комиссии. Комиссия примерно десятая часть взноса — это и есть
  доход рума с турнира, потому что рейка с банка здесь нет и быть не
  может.
  """
  @spec rows(keyword()) :: [map()]
  def rows(opts \\ []) do
    for currency <- currencies(opts[:currency]),
        {buy_in, fee} <- prices(currency),
        speed <- speeds(opts[:speed]),
        game_type <- game_types(opts[:game_type]) do
      row(currency, buy_in, fee, speed, game_type)
    end
  end

  defp row(currency, buy_in, fee, speed, game_type) do
    %{
      attrs: %{
        name: name(currency, buy_in, fee, speed, game_type),
        description: description(speed),
        game_type: game_type,
        currency: currency,
        buy_in: buy_in,
        entry_fee: fee,
        starting_stack: 5000,
        table_size: 6,
        min_players: 2,
        max_players: 1000,
        rebuy_allowed: true,
        max_rebuys: 2,
        addon_cost: div(buy_in, 2),
        addon_stack: 5000,
        registration_opens_before: 3600,
        cancel_refund_grace_seconds: 300,
        sort_order: sort_order(currency, buy_in)
      },
      levels: blind_levels(speed),
      payouts: payouts(),
      schedules: schedules(speed)
    }
  end

  # Расписание задаёт лицо рума: обычные турниры вечером, турбо чаще,
  # гипер — каждый час, потому что он длится сорок минут.
  defp schedules(:hyper), do: [%{start_time: ~T[20:00:00], repeat: true}]
  defp schedules(:turbo), do: [%{start_time: ~T[21:00:00], repeat: true}]
  defp schedules(_regular), do: [%{start_time: ~T[21:30:00], repeat: true}]

  defp name(currency, buy_in, fee, speed, game_type) do
    "#{discipline_label(game_type)} #{speed_label(speed)} #{price_label(currency, buy_in + fee)}"
  end

  defp description(:hyper), do: "Уровень три минуты: турнир на один вечер"
  defp description(:turbo), do: "Уровень пять минут"
  defp description(_regular), do: "Классическая структура, уровень десять минут"

  defp discipline_label(:short_deck), do: "Short Deck"
  defp discipline_label(_holdem), do: "Hold'em"

  defp speed_label(:hyper), do: "Hyper"
  defp speed_label(:turbo), do: "Turbo"
  defp speed_label(_regular), do: "Regular"

  # Цена печатается так, как её видит игрок: доллары для реальных денег,
  # целые фишки для игровых.
  defp price_label(:main, price), do: "$#{div(price, 100)}.#{pad(rem(price, 100))}"
  defp price_label(:play_money, price), do: "#{price}"

  defp pad(cents), do: String.pad_leading(Integer.to_string(cents), 2, "0")

  # Порядок витрины внутри валюты — по цене входа: дешёвые выше.
  defp sort_order(:main, buy_in), do: div(buy_in, 100)
  defp sort_order(:play_money, buy_in), do: div(buy_in, 1000)

  # Взнос и комиссия. Комиссия — примерно десятая часть, округлённая
  # к привычной глазу цифре.
  defp prices(:main), do: [{100, 10}, {500, 50}, {2000, 200}, {10_000, 900}]
  defp prices(:play_money), do: [{10_000, 1000}, {50_000, 5000}, {200_000, 18_000}]

  defp currencies(nil), do: [:main, :play_money]
  defp currencies(currency), do: [currency]

  defp speeds(nil), do: [:regular, :turbo, :hyper]
  defp speeds(speed), do: [speed]

  defp game_types(nil), do: [:texas_holdem]
  defp game_types(game_type), do: [game_type]

  @doc """
  Разворачивает сетку в БД. Идемпотентно: шаблон с тем же естественным
  ключом пропускается.

  Перезаписи нет намеренно — в отличие от кэша, правка шаблона тянет за
  собой уровни, выплаты и расписание, и молча заменять их набор опаснее,
  чем ничего не делать.
  """
  @spec seed([map()]) :: %{created: [String.t()], skipped: [String.t()], failed: [tuple()]}
  def seed(rows) do
    Enum.reduce(rows, %{created: [], skipped: [], failed: []}, fn row, acc ->
      case Tournaments.create_setting(row.attrs, row.levels, row.payouts, row.schedules) do
        {:ok, setting} ->
          %{acc | created: acc.created ++ [setting.name]}

        {:error, %Ecto.Changeset{} = changeset} ->
          if duplicate?(changeset) do
            %{acc | skipped: acc.skipped ++ [row.attrs.name]}
          else
            %{acc | failed: acc.failed ++ [{row.attrs.name, changeset}]}
          end

        {:error, reason} ->
          %{acc | failed: acc.failed ++ [{row.attrs.name, reason}]}
      end
    end)
  end

  defp duplicate?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
      opts[:constraint] == :unique
    end)
  end
end
