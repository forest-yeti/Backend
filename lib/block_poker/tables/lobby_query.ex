defmodule BlockPoker.Tables.LobbyQuery do
  @moduledoc """
  Фильтрация и сортировка витрины лобби — чистые функции над снапшотом.

  Живёт в ядре, а не в канале, потому что «микролимит», «6-max» и «сперва
  Main, потом PlayMoney» — доменные понятия: они завязаны на блайнды,
  количество мест и валюту, то есть на правила рума, а не на транспорт.
  Канал только передаёт сюда сырой payload (§3 CLAUDE.md).

  ## Порядок по умолчанию

  Когда не выбран ни один фильтр и не задана сортировка, порядок такой:
  сперва все столы валюты `main` от младшего лимита к старшему, затем
  тем же порядком `play_money`. Группировка по валюте — не сортировка,
  а разделение витрины: она сохраняется и при явной сортировке, иначе
  «лимит по убыванию» смешал бы центы с игровыми фишками в один список.

  Поле `sort_order` шаблона витриной **не используется**: порядок выводится
  из валюты и блайндов, то есть из того, что игрок видит в строке лобби,
  а не из служебного индекса сида.

  ## Границы лимитов

  Уровень `NLx` — это стол, где 100bb стоят `x` (см. `priv/cash_games/grid.exs`),
  поэтому категория считается от большого блайнда, а не от имени шаблона:
  имя оператор вправе переписать, блайнды — нет.
  """

  alias BlockPoker.CashGames.CashGameSetting
  alias BlockPoker.Engine.Variant.Registry, as: VariantRegistry
  alias BlockPoker.Tables.Blueprint
  alias BlockPoker.Tournaments.TournamentSetting

  @type entry :: %{required(:setting) => term(), optional(atom()) => term()}

  @type t :: %__MODULE__{
          category: Blueprint.category() | :tournament,
          game_types: [atom()],
          currencies: [atom()],
          table_sizes: [atom()],
          limit_tiers: [atom()],
          statuses: [atom()],
          kinds: [atom()],
          mine: boolean(),
          has_ticket: boolean(),
          sort: {:limit | :occupancy, :asc | :desc} | nil
        }

  defstruct category: :cash,
            game_types: [],
            currencies: [],
            table_sizes: [],
            limit_tiers: [],
            # Турнирные фильтры. У кэша их нет, и пустыми они ему не мешают:
            # пустой список фильтром не является.
            statuses: [],
            kinds: [],
            # Персональные фильтры: считаются от `user_id` сокета, в payload
            # не приходят и приходить не должны.
            mine: false,
            has_ticket: false,
            sort: nil

  @currencies CashGameSetting.currencies()
  @table_sizes [:heads_up, :six_max, :nine_max]
  @limit_tiers [:micro, :medium, :high_roller]
  @sort_fields [:limit, :occupancy]
  # Сортировки турнирной витрины. Набор другой, потому что у турнира нет
  # ни лимита, ни занятости: игрок выбирает по цене, по времени до старта
  # и по тому, сколько народу уже вошло.
  @tournament_sort_fields [:entry_price, :starts_at, :entries]
  @statuses [:announced, :registering, :running, :late_reg, :finished]
  @kinds [:freeroll, :rebuy, :bounty, :satellite]
  @sort_directions [:asc, :desc]

  # Верхние границы категорий в больших блайндах, по валютам.
  # main:       NL2..NL10 — микро, NL20..NL500 — средние, NL800+ — хайроллеры.
  # play_money: NL1000..NL10000 — микро, NL30000..NL50000 — средние, дальше хайроллеры.
  # Границы турнирных категорий — в цене входа, а не в блайндах.
  # main:       до $5 — микро, до $100 — средние, дальше хайроллеры.
  # play_money: те же ступени, но в игровых фишках.
  @entry_bounds %{
    main: [micro: 500, medium: 10_000],
    play_money: [micro: 50_000, medium: 1_000_000]
  }

  @tier_bounds %{
    main: [micro: 10, medium: 500],
    play_money: [micro: 100, medium: 500]
  }

  # Валюта задаёт разделы витрины, и их порядок фиксирован: реальные деньги
  # выше игровых.
  @currency_order Enum.with_index(@currencies) |> Map.new()

  @spec currencies() :: [atom()]
  def currencies, do: @currencies

  @spec table_sizes() :: [atom()]
  def table_sizes, do: @table_sizes

  @spec limit_tiers() :: [atom()]
  def limit_tiers, do: @limit_tiers

  @spec sort_fields() :: [atom()]
  def sort_fields, do: @sort_fields

  @spec tournament_sort_fields() :: [atom()]
  def tournament_sort_fields, do: @tournament_sort_fields

  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc """
  Разбор запроса клиента. Неизвестное значение — ошибка, а не молчаливое
  игнорирование: иначе опечатка в фильтре выглядит как пустой рум.
  """
  @spec parse(map() | nil, Blueprint.category()) :: {:ok, t()} | {:error, :validation_failed}
  def parse(params, category \\ :cash)

  def parse(nil, category), do: {:ok, %__MODULE__{category: category}}

  def parse(params, category) when is_map(params) do
    with {:ok, game_types} <- list(params, "game_types", VariantRegistry.ids()),
         {:ok, currencies} <- list(params, "currencies", @currencies),
         {:ok, table_sizes} <- list(params, "table_sizes", @table_sizes),
         {:ok, limit_tiers} <- list(params, "limit_tiers", @limit_tiers),
         {:ok, statuses} <- list(params, "statuses", @statuses),
         {:ok, kinds} <- list(params, "kinds", @kinds),
         {:ok, sort} <- sort(params, category) do
      {:ok,
       %__MODULE__{
         category: category,
         game_types: game_types,
         currencies: currencies,
         table_sizes: table_sizes,
         limit_tiers: limit_tiers,
         statuses: statuses,
         kinds: kinds,
         # Персональные фильтры — булевы: «мои» и «куда пускает мой билет».
         # Чьи именно, решает не payload, а сокет.
         mine: params["mine"] == true,
         has_ticket: params["has_ticket"] == true,
         sort: sort
       }}
    end
  end

  def parse(_params, _category), do: {:error, :validation_failed}

  @doc "Отфильтрованный и отсортированный снапшот."
  @spec apply(t(), [entry()]) :: [entry()]
  def apply(%__MODULE__{} = query, entries) do
    entries
    |> Enum.filter(&matches?(query, &1))
    |> Enum.sort_by(&sort_key(query, &1))
  end

  @doc """
  Проходит ли шаблон текущий фильтр. Нужен не только `apply/2`: по нему
  канал решает, доезжает ли до подписчика инкрементальный `lobby_delta`.
  """
  @spec matches?(t(), entry()) :: boolean()
  def matches?(%__MODULE__{category: :tournament} = query, entry) do
    setting = entry.setting

    in?(query.game_types, setting.game_type) and
      in?(query.currencies, setting.currency) and
      in?(query.table_sizes, tournament_table_size(setting)) and
      in?(query.limit_tiers, tournament_limit_tier(setting)) and
      in?(query.statuses, entry.status) and
      matches_kinds?(query.kinds, entry.kinds) and
      (not query.mine or entry.registered) and
      (not query.has_ticket or entry.has_ticket)
  end

  def matches?(%__MODULE__{} = query, %{setting: setting}) do
    Blueprint.category(setting) == query.category and
      in?(query.game_types, Blueprint.game_type(setting)) and
      in?(query.currencies, Blueprint.currency(setting)) and
      in?(query.table_sizes, table_size(setting)) and
      in?(query.limit_tiers, limit_tier(setting))
  end

  # Признаков у турнира может быть несколько (ребайный баунти-саттелит),
  # и фильтр по ним — «хотя бы один из выбранных», а не «все сразу»:
  # игрок отмечает галки «фрироллы» и «баунти», ожидая объединение.
  defp matches_kinds?([], _kinds), do: true
  defp matches_kinds?(wanted, kinds), do: Enum.any?(kinds, &(&1 in wanted))

  @doc """
  Формат турнирного стола. Считается по `table_size` — по тому, сколько
  сидит за одним столом, — а не по числу участников: турнир на триста
  человек играется за шестимаксными столами и в витрине он `six_max`.
  """
  @spec tournament_table_size(TournamentSetting.t()) :: :heads_up | :six_max | :nine_max
  def tournament_table_size(%TournamentSetting{table_size: size}) do
    case size do
      2 -> :heads_up
      6 -> :six_max
      _nine -> :nine_max
    end
  end

  @doc """
  Категория лимита турнира — **от цены входа**, а не от блайндов.

  Блайнды в турнире растут и к пятому уровню ничего не говорят о том,
  дорогой это турнир или дешёвый. Цена входа не меняется никогда, и
  именно её игрок сравнивает.
  """
  @spec tournament_limit_tier(TournamentSetting.t()) :: :micro | :medium | :high_roller
  def tournament_limit_tier(%TournamentSetting{} = setting) do
    bounds = Map.get(@entry_bounds, setting.currency, [])
    price = TournamentSetting.entry_price(setting)

    Enum.find_value(bounds, :high_roller, fn {tier, max_price} ->
      if price <= max_price, do: tier
    end)
  end

  @doc "Формат стола по количеству мест."
  @spec table_size(term()) :: :heads_up | :six_max | :nine_max
  def table_size(setting) do
    case Blueprint.max_players(setting) do
      max when max <= 2 -> :heads_up
      max when max <= 6 -> :six_max
      _max -> :nine_max
    end
  end

  @doc """
  Категория лимита: микро / средний / хайроллер.

  Считается от базовой единицы стола, а не от большого блайнда: на анте-столе
  блайндов нет, и «лимит 0» отправлял бы все такие столы в микро.
  """
  @spec limit_tier(term()) :: :micro | :medium | :high_roller
  def limit_tier(setting) do
    bounds = Map.get(@tier_bounds, Blueprint.currency(setting), [])
    unit = Blueprint.bet_unit(setting)

    Enum.find_value(bounds, :high_roller, fn {tier, max_unit} ->
      if unit <= max_unit, do: tier
    end)
  end

  # --- разбор --------------------------------------------------------------

  # Пустой список = фильтр не выбран, а не «ничего не показывать»: снятая
  # последняя галка должна возвращать полную витрину.
  defp in?([], _value), do: true
  defp in?(allowed, value), do: value in allowed

  defp list(params, key, allowed) do
    case Map.get(params, key) do
      nil -> {:ok, []}
      [] -> {:ok, []}
      values when is_list(values) -> cast_all(values, allowed)
      _other -> {:error, :validation_failed}
    end
  end

  defp cast_all(values, allowed) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case cast(value, allowed) do
        {:ok, atom} -> {:cont, {:ok, [atom | acc]}}
        :error -> {:halt, {:error, :validation_failed}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, acc |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp cast(value, allowed) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> :error
      atom -> {:ok, atom}
    end
  end

  defp cast(value, allowed) when is_atom(value) do
    if value in allowed, do: {:ok, value}, else: :error
  end

  defp cast(_value, _allowed), do: :error

  defp sort(params, category) do
    case Map.get(params, "sort") do
      nil ->
        {:ok, nil}

      %{} = sort ->
        with {:ok, [field]} <- cast_one(sort, "field", sort_fields_of(category)),
             {:ok, direction} <- direction(sort) do
          {:ok, {field, direction}}
        end

      _other ->
        {:error, :validation_failed}
    end
  end

  defp sort_fields_of(:tournament), do: @tournament_sort_fields
  defp sort_fields_of(_category), do: @sort_fields

  defp cast_one(sort, key, allowed) do
    case Map.get(sort, key) do
      nil -> {:error, :validation_failed}
      value -> cast_all([value], allowed)
    end
  end

  defp direction(sort) do
    case cast_all([Map.get(sort, "direction", "asc")], @sort_directions) do
      {:ok, [direction]} -> {:ok, direction}
      _other -> {:error, :validation_failed}
    end
  end

  # --- сортировка ----------------------------------------------------------

  # Ключ строится так, чтобы `Enum.sort_by/2` оставался стабильным: валюта —
  # всегда первым разрядом, дальше выбранный параметр, дальше — умолчание,
  # разводящее шаблоны с одинаковым лимитом.
  # Турнирная витрина сортируется по **отношению игрока к турниру**, а не
  # по свойствам турнира: первым идёт то, что требует его внимания.
  #
  #   1. **свои** — где он зарегистрирован, независимо от стадии: это
  #      единственные строки, где от него чего-то ждут;
  #   2. **идущие** — от начавшихся раньше к начавшимся позже: чем дольше
  #      турнир идёт, тем ближе он к деньгам и тем интереснее смотреть;
  #   3. **будущие** — ближайший старт первым: игрок выбирает, во что
  #      успевает;
  #   4. **сыгранные** — в самом низу.
  #
  # Внутри группы разряд один и тот же — время старта по возрастанию, — и
  # он же даёт «дольше всех идёт» во второй группе и «скорее всех
  # начнётся» в третьей.
  #
  # Валюта здесь **не** первым разрядом, в отличие от кэша: турнир, в
  # который игрок вошёл, не должен уезжать вниз оттого, что он на фишки.
  defp sort_key(%__MODULE__{category: :tournament} = query, entry) do
    # Свои турниры — **безусловно** первым разрядом, при любой выбранной
    # сортировке: это единственные строки, где от игрока чего-то ждут,
    # и искать их среди трёхсот чужих он не должен.
    {registered_rank(entry), tournament_order(query.sort, entry)}
  end

  defp sort_key(%__MODULE__{sort: nil}, entry), do: default_key(entry)

  defp sort_key(%__MODULE__{sort: {:limit, direction}}, entry) do
    %{setting: setting} = entry

    {currency_rank(setting), signed(Blueprint.bet_unit(setting), direction), default_key(entry)}
  end

  defp sort_key(%__MODULE__{sort: {:occupancy, direction}}, entry) do
    {currency_rank(entry.setting), signed(occupancy(entry), direction), default_key(entry)}
  end

  defp registered_rank(%{registered: true}), do: 0
  defp registered_rank(_entry), do: 1

  # Умолчание витрины: сначала идущие — от начавшихся раньше к
  # начавшимся позже, потому что дольше играющий турнир ближе к
  # деньгам, — потом будущие по ближайшему старту, потом сыгранные.
  defp tournament_order(nil, entry) do
    {stage_rank(entry), currency_rank(entry.setting), starts_unix(entry), entry.entry_price,
     entry.tournament_id}
  end

  defp tournament_order({:starts_at, direction}, entry) do
    {signed(starts_unix(entry), direction), entry.entry_price, entry.tournament_id}
  end

  defp tournament_order({:entry_price, direction}, entry) do
    {signed(entry.entry_price, direction), starts_unix(entry), entry.tournament_id}
  end

  # «Сколько уже вошло» считается по входам, а не по людям: игрок
  # выбирает турнир по размеру поля, а поле — это входы.
  defp tournament_order({:entries, direction}, entry) do
    {signed(entry.tournament.entries_count, direction), starts_unix(entry), entry.tournament_id}
  end

  defp starts_unix(entry), do: DateTime.to_unix(entry.starts_at, :microsecond)

  defp stage_rank(%{status: status}) when status in [:running, :late_reg], do: 1
  defp stage_rank(%{status: status}) when status in [:announced, :registering], do: 2
  defp stage_rank(_entry), do: 3

  # Умолчание разводит шаблоны с одинаковым лимитом. Базовая единица и
  # вместимость есть у любого стола; всё, что дальше, — уже частности
  # блайндового, и спрашиваются они только у него.
  defp default_key(%{setting: setting}) do
    {currency_rank(setting), Blueprint.bet_unit(setting), Blueprint.max_players(setting),
     tie_break(setting), setting.id}
  end

  defp tie_break(%CashGameSetting{} = setting), do: {setting.small_blind, setting.ante}
  defp tie_break(_setting), do: {0, 0}

  defp currency_rank(%TournamentSetting{currency: currency}) do
    Map.get(@currency_order, currency, 99)
  end

  defp currency_rank(setting), do: Map.get(@currency_order, Blueprint.currency(setting), 99)

  # Занятость лимита — это заполненность той комнаты, куда игрока посадит
  # быстрый вход: игрок сравнивает «2/9» и «8/9», а не сумму по всем комнатам.
  defp occupancy(entry), do: Map.get(entry, :seats_taken, 0)

  defp signed(value, :asc), do: value
  defp signed(value, :desc), do: -value
end
