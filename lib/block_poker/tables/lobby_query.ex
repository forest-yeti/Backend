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

  @type entry :: %{required(:setting) => CashGameSetting.t(), optional(atom()) => term()}

  @type t :: %__MODULE__{
          game_types: [atom()],
          currencies: [atom()],
          table_sizes: [atom()],
          limit_tiers: [atom()],
          sort: {:limit | :occupancy, :asc | :desc} | nil
        }

  defstruct game_types: [], currencies: [], table_sizes: [], limit_tiers: [], sort: nil

  @currencies CashGameSetting.currencies()
  @table_sizes [:heads_up, :six_max, :nine_max]
  @limit_tiers [:micro, :medium, :high_roller]
  @sort_fields [:limit, :occupancy]
  @sort_directions [:asc, :desc]

  # Верхние границы категорий в больших блайндах, по валютам.
  # main:       NL2..NL10 — микро, NL20..NL500 — средние, NL800+ — хайроллеры.
  # play_money: NL1000..NL10000 — микро, NL30000..NL50000 — средние, дальше хайроллеры.
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

  @doc """
  Разбор запроса клиента. Неизвестное значение — ошибка, а не молчаливое
  игнорирование: иначе опечатка в фильтре выглядит как пустой рум.
  """
  @spec parse(map() | nil) :: {:ok, t()} | {:error, :validation_failed}
  def parse(nil), do: {:ok, %__MODULE__{}}

  def parse(params) when is_map(params) do
    with {:ok, game_types} <- list(params, "game_types", VariantRegistry.ids()),
         {:ok, currencies} <- list(params, "currencies", @currencies),
         {:ok, table_sizes} <- list(params, "table_sizes", @table_sizes),
         {:ok, limit_tiers} <- list(params, "limit_tiers", @limit_tiers),
         {:ok, sort} <- sort(params) do
      {:ok,
       %__MODULE__{
         game_types: game_types,
         currencies: currencies,
         table_sizes: table_sizes,
         limit_tiers: limit_tiers,
         sort: sort
       }}
    end
  end

  def parse(_params), do: {:error, :validation_failed}

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
  def matches?(%__MODULE__{} = query, %{setting: setting}) do
    in?(query.game_types, setting.game_type) and
      in?(query.currencies, setting.currency) and
      in?(query.table_sizes, table_size(setting)) and
      in?(query.limit_tiers, limit_tier(setting))
  end

  @doc "Формат стола по количеству мест."
  @spec table_size(CashGameSetting.t()) :: :heads_up | :six_max | :nine_max
  def table_size(%CashGameSetting{max_players: max}) when max <= 2, do: :heads_up
  def table_size(%CashGameSetting{max_players: max}) when max <= 6, do: :six_max
  def table_size(%CashGameSetting{}), do: :nine_max

  @doc "Категория лимита: микро / средний / хайроллер."
  @spec limit_tier(CashGameSetting.t()) :: :micro | :medium | :high_roller
  def limit_tier(%CashGameSetting{} = setting) do
    bounds = Map.get(@tier_bounds, setting.currency, [])

    Enum.find_value(bounds, :high_roller, fn {tier, max_big_blind} ->
      if setting.big_blind <= max_big_blind, do: tier
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

  defp sort(params) do
    case Map.get(params, "sort") do
      nil ->
        {:ok, nil}

      %{} = sort ->
        with {:ok, [field]} <- cast_one(sort, "field", @sort_fields),
             {:ok, direction} <- direction(sort) do
          {:ok, {field, direction}}
        end

      _other ->
        {:error, :validation_failed}
    end
  end

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
  defp sort_key(%__MODULE__{sort: nil}, entry), do: default_key(entry)

  defp sort_key(%__MODULE__{sort: {:limit, direction}}, entry) do
    %{setting: setting} = entry
    {currency_rank(setting), signed(setting.big_blind, direction), default_key(entry)}
  end

  defp sort_key(%__MODULE__{sort: {:occupancy, direction}}, entry) do
    {currency_rank(entry.setting), signed(occupancy(entry), direction), default_key(entry)}
  end

  defp default_key(%{setting: setting}) do
    {currency_rank(setting), setting.big_blind, setting.small_blind, setting.max_players,
     setting.ante, setting.id}
  end

  defp currency_rank(setting), do: Map.get(@currency_order, setting.currency, 99)

  # Занятость лимита — это заполненность той комнаты, куда игрока посадит
  # быстрый вход: игрок сравнивает «2/9» и «8/9», а не сумму по всем комнатам.
  defp occupancy(entry), do: Map.get(entry, :seats_taken, 0)

  defp signed(value, :asc), do: value
  defp signed(value, :desc), do: -value
end
