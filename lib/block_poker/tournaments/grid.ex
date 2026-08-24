defmodule BlockPoker.Tournaments.Grid do
  @moduledoc """
  Сетка турниров рума: шаблоны, структуры уровней, выплаты и расписание.

  Живёт в коде, а не в SQL-файле, по той же причине, что и сетка
  Sit & Go: экономика турнира — это свойство набора строк, и её нужно
  уметь проверить тестом. Сид только раскладывает посчитанное по таблицам.

  ## Что задаёт сетку

  Семь семейств на реальные деньги и четыре тестовых на фишки. Семейство
  задаёт дисциплину, структуру уровней, расписание и цвет стола; цена
  входа разворачивает его в отдельные шаблоны, потому что взнос — поле
  шаблона, а не турнира.

  Скорость турнира — это **длительность уровня**, а не номиналы: гипер
  играет вдвое быстрее классики на той же лесенке блайндов, и стек тает
  относительно них вдвое быстрее.

  ## Правила, вшитые в сетку

    * **вход всегда открыт и всегда неограничен.** Ре-энтри без счётчика,
      пока его разрешает уровень: час игры у гипера, два часа у долгих.
      Дальше стартовый стек перестаёт быть игровым, и возвращаться некуда;
    * **аддона нет нигде.** Докупка на перерыве меняет расклад сил
      в середине турнира, и рум её не продаёт;
    * **комиссия не входит во взнос.** `$1` в названии — это `0.90$`
      в фонд и `0.10$` руму;
    * **голова берётся из взноса**, а не сверх него: в баунти-семействах
      половина взноса становится ценой головы и делится пополам — деньги
      убийце и прирост его собственной головы (PKO);
    * **финальный стол выглядит одинаково везде** — тёмное золото. Это
      признак стадии, а не семейства: игрок обязан узнавать финалку
      по цвету, за каким бы турниром он ни сидел.

  ## Правило выплат

  Доли внутри диапазона обязаны складываться ровно в миллион, не
  возрастать с местом и не оплачивать мест больше, чем входов в этом
  диапазоне. Всё это проверяет `Engine.TournamentPayout.validate/3`,
  и оно же падает в CI, если правку сетки сделали неаккуратно.
  """

  alias BlockPoker.Tournaments

  # Стартовый стек и лесенка подобраны так, чтобы первый уровень давал
  # ровно сто больших блайндов: это точка отсчёта, по которой игрок
  # читает структуру.
  @starting_stack 10_000

  # Одна лесенка на все семейства. Анте — примерно десятая часть большого
  # блайнда: достаточно, чтобы борьба за мёртвые деньги началась сразу,
  # и мало, чтобы не съедать короткие стеки на первых уровнях.
  @ladder [
    {50, 100, 10},
    {75, 150, 15},
    {100, 200, 25},
    {150, 300, 35},
    {200, 400, 50},
    {300, 600, 75},
    {400, 800, 100},
    {500, 1000, 125},
    {700, 1400, 175},
    {1000, 2000, 250},
    {1500, 3000, 350},
    {2000, 4000, 500},
    {3000, 6000, 750},
    {4000, 8000, 1000},
    {5000, 10_000, 1250},
    {7000, 14_000, 1750},
    {10_000, 20_000, 2500},
    {15_000, 30_000, 3500},
    {20_000, 40_000, 5000},
    {30_000, 60_000, 7500},
    {40_000, 80_000, 10_000},
    {60_000, 120_000, 15_000},
    {80_000, 160_000, 20_000},
    {120_000, 240_000, 30_000}
  ]

  # Структура — это длительность уровня и окно входа. Окно задано
  # временем, а не числом уровней: «час игры» одинаково читается
  # и в гипере, и в долгом, а сколько это уровней — арифметика.
  @structures %{
    hyper: %{duration: 300, reentry_window: 3600},
    classic: %{duration: 600, reentry_window: 7200},
    short: %{duration: 420, reentry_window: 7200},
    deep: %{duration: 900, reentry_window: 7200},
    dev: %{duration: 120, reentry_window: 600}
  }

  # Цены: взнос и комиссия раздельно. Доля комиссии падает с ростом
  # входа — так устроен любой рум: обслуживание дорогого турнира стоит
  # столько же, сколько дешёвого.
  @prices %{
    1 => {90, 10},
    3 => {270, 30},
    10 => {900, 100},
    30 => {2700, 300},
    50 => {4550, 450},
    80 => {7440, 560},
    100 => {9300, 700},
    250 => {23_750, 1250},
    400 => {38_000, 2000},
    800 => {76_000, 4000},
    1500 => {142_500, 7500}
  }

  @visuals %{
    green: {"#1F6F4A", "#10241C"},
    red: {"#6E2C2C", "#1E0F0F"},
    purple: {"#3F2A63", "#150E22"}
  }

  # Финальный стол — тёмное золото, одинаково у всех семейств.
  @final_visual {"#6B5518", "#191206"}

  @templates [
    %{
      name: "Hyper For Us",
      description: "Гипер: уровень пять минут, старт каждые полчаса",
      game_type: :texas_holdem,
      structure: :hyper,
      visual: :green,
      schedule: {:every, 30},
      prices: [1, 3, 10, 30, 50],
      bounty: false
    },
    %{
      name: "Classic",
      description: "Классическая структура: уровень десять минут",
      game_type: :texas_holdem,
      structure: :classic,
      visual: :red,
      schedule: {:every, 60},
      prices: [1, 3, 10, 30, 50, 80, 100],
      bounty: false
    },
    %{
      name: "High Roller Classic",
      description: "Классическая структура для крупных ставок",
      game_type: :texas_holdem,
      structure: :classic,
      visual: :purple,
      schedule: {:every, 180},
      prices: [250, 400, 800],
      bounty: false
    },
    %{
      name: "Bounty Hunter Classic",
      description: "Прогрессивный нокаут: половина взноса — голова",
      game_type: :texas_holdem,
      structure: :classic,
      visual: :green,
      schedule: {:every, 60},
      prices: [1, 3, 10, 30, 50],
      bounty: true
    },
    %{
      name: "Bounty Hunter - Hyper For Us",
      description: "Прогрессивный нокаут на гипер-структуре",
      game_type: :texas_holdem,
      structure: :hyper,
      visual: :green,
      schedule: {:every, 60},
      prices: [1, 3, 10, 30, 50, 80, 100],
      bounty: true
    },
    %{
      name: "Fewer Cards, More Action - ShortDeck",
      description: "Короткая колода, уровень семь минут",
      game_type: :short_deck,
      structure: :short,
      visual: :red,
      schedule: {:every, 60},
      prices: [1, 3, 10, 30, 50, 80, 100],
      bounty: false
    },
    %{
      name: "Big High Roller",
      description: "Главный турнир недели: уровень пятнадцать минут",
      game_type: :texas_holdem,
      structure: :deep,
      visual: :purple,
      # Суббота, 01:00 по времени рума.
      schedule: {:weekly, 6, ~T[01:00:00]},
      prices: [1500],
      bounty: false
    }
  ]

  # Тестовые семейства: игровые фишки, старт от трёх человек и запуск
  # каждую минуту. Живут в той же сетке, а не в фикстурах, потому что
  # разработчику нужен турнир на живом руме, а не в песочнице.
  @dev_templates [
    %{
      name: "Develop for us - Holdem 6-Max",
      description: "Тестовый: старт от трёх, запуск каждую минуту",
      game_type: :texas_holdem,
      table_size: 6,
      bounty: false
    },
    %{
      name: "Develop for us - Holdem 6-Max PKO",
      description: "Тестовый баунти: старт от трёх, запуск каждую минуту",
      game_type: :texas_holdem,
      table_size: 6,
      bounty: true
    },
    %{
      name: "Develop for us - Heads-Up",
      description: "Тестовый хедз-ап: запуск каждую минуту",
      game_type: :texas_holdem,
      table_size: 2,
      bounty: false
    },
    %{
      name: "Develop for us - ShortDeck",
      description: "Тестовая короткая колода: запуск каждую минуту",
      game_type: :short_deck,
      table_size: 6,
      bounty: false
    }
  ]

  @doc """
  Структура уровней семейства.

  Короткая колода играется на анте вместо блайндов (`Variant.ShortDeck`
  ставит `BettingStructure.ButtonAnte`), поэтому у неё та же лесенка
  записана одной колонкой.

  Ребайные уровни считаются из окна входа: `rebuy_allowed` стоит там,
  куда турнир успевает дойти за час (гипер) или за два (долгие
  структуры).
  """
  @spec blind_levels(atom(), atom()) :: [map()]
  def blind_levels(structure, game_type \\ :texas_holdem) do
    %{duration: duration, reentry_window: window} = Map.fetch!(@structures, structure)

    open_until = div(window, duration)

    @ladder
    |> Enum.with_index(1)
    |> Enum.map(fn {limits, level} ->
      Map.merge(
        %{
          level: level,
          duration_seconds: duration,
          rebuy_allowed: level <= open_until,
          # Аддона нет ни в одном турнире рума.
          addon_allowed: false
        },
        limits(game_type, limits)
      )
    end)
  end

  defp limits(:short_deck, {_small, big, _ante}), do: %{small_blind: 0, big_blind: 0, ante: big}
  defp limits(_holdem, {small, big, ante}), do: %{small_blind: small, big_blind: big, ante: ante}

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
  Шаблоны сетки: по одному на каждую цену каждого семейства.

  `only: :main | :play_money` сужает набор до боевых или тестовых.
  """
  @spec rows(keyword()) :: [map()]
  def rows(opts \\ []) do
    case Keyword.get(opts, :only) do
      :main -> main_rows()
      :play_money -> dev_rows()
      nil -> main_rows() ++ dev_rows()
    end
  end

  defp main_rows do
    for template <- @templates, price <- template.prices do
      {buy_in, fee} = Map.fetch!(@prices, price)

      row(template, %{
        name: "#{template.name} $#{price}",
        currency: :main,
        buy_in: buy_in,
        entry_fee: fee,
        table_size: 6,
        min_players: 6,
        structure: template.structure,
        schedules: schedules(template.schedule),
        registration_opens_before: opens_before(template.structure),
        sort_order: price
      })
    end
  end

  defp dev_rows do
    for template <- @dev_templates do
      row(template, %{
        name: template.name,
        currency: :play_money,
        buy_in: 100,
        entry_fee: 10,
        table_size: template.table_size,
        # Тестовый турнир обязан стартовать втроём: собрать шестерых
        # разработчиков к каждой минуте невозможно.
        min_players: 3,
        structure: :dev,
        schedules: schedules({:every, 1}),
        registration_opens_before: 120,
        sort_order: 0
      })
    end
  end

  defp row(template, params) do
    %{
      attrs:
        Map.merge(
          %{
            name: params.name,
            description: template.description,
            game_type: template.game_type,
            currency: params.currency,
            buy_in: params.buy_in,
            entry_fee: params.entry_fee,
            starting_stack: @starting_stack,
            table_size: params.table_size,
            min_players: params.min_players,
            max_players: 10_000,
            # Ре-энтри без счётчика: ограничивает их уровень, а не лимит.
            rebuy_allowed: true,
            max_rebuys: nil,
            # Аддона нет: нулевая цена и есть его отсутствие.
            addon_cost: 0,
            addon_stack: 0,
            bounty_part: bounty_part(template, params.buy_in),
            bounty_progressive: template.bounty,
            registration_opens_before: params.registration_opens_before,
            cancel_refund_grace_seconds: 300,
            sort_order: params.sort_order
          },
          colors(template)
        ),
      levels: blind_levels(params.structure, template.game_type),
      payouts: payouts(),
      schedules: params.schedules
    }
  end

  # Половина взноса становится головой. Делится она пополам (умолчание
  # `bounty_split_ppm`): половина деньгами убийце, половина в его
  # собственную голову — это и есть PKO.
  defp bounty_part(%{bounty: true}, buy_in), do: div(buy_in, 2)
  defp bounty_part(_template, _buy_in), do: 0

  # У тестовых семейств своего цвета нет: они инструмент, а не витрина.
  defp colors(template) do
    {felt, background} = Map.fetch!(@visuals, Map.get(template, :visual, :green))
    {final_felt, final_background} = @final_visual

    %{
      felt_color: felt,
      background_color: background,
      final_felt_color: final_felt,
      final_background_color: final_background
    }
  end

  # Запуск каждые N минут разворачивается в строки расписания: одна
  # строка — одно время суток. Отдельного «интервала» в схеме нет
  # намеренно, иначе о том, когда стартует турнир, знали бы два поля.
  defp schedules({:every, minutes}) do
    for minute <- 0..(1440 - 1)//minutes do
      %{start_time: Time.new!(div(minute, 60), rem(minute, 60), 0), repeat: true}
    end
  end

  defp schedules({:weekly, weekday, time}) do
    [%{start_time: time, weekday: weekday, repeat: true}]
  end

  # Регистрация открывается не раньше, чем стартовал предыдущий запуск
  # того же семейства: иначе витрина показывает три одинаковых турнира,
  # и игрок не понимает, в какой из них он вошёл.
  defp opens_before(:hyper), do: 1800
  defp opens_before(_structure), do: 3600

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
