defmodule BlockPoker.Tournaments.TournamentSetting do
  @moduledoc """
  Шаблон турнира: **условия**, а не запуск.

  Из одной строки поднимаются десятки инстансов — сегодняшний в 21:30 и
  завтрашний в 21:30 разные турниры с одинаковыми правилами. Это главное
  отличие от Sit & Go, где шаблон и пул почти совпадали: там турнир
  стартовал по набору, здесь — по часам, и «когда» живёт отдельной
  таблицей расписания.

  ## Что задаёт шаблон и чего в нём нет

  `table_size` — сколько сидит **за одним столом**, а не сколько человек
  в турнире: столов поднимается столько, сколько нужно, чтобы рассадить
  явку. `min_players` и `max_players` считаются по **людям**, `max_entries`
  — по **входам**: ре-энтри делает эти числа разными, и путать их нельзя.

  Чего нет намеренно:

    * **рейка с банка** — банк в фишках, доход рума это `entry_fee`;
    * **границ бай-ина** — взнос фиксирован, иначе стартовые стеки
      разъехались бы;
    * **числа призовых мест** — оно выводится из явки по сетке выплат;
    * **`late_reg_level`** — правило поздней регистрации живёт во флагах
      уровней, и второй источник правды о том же моменте был бы багом.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BlockPoker.Engine.BettingStructure
  alias BlockPoker.Engine.Variant.Registry, as: VariantRegistry
  alias BlockPoker.Tickets.Ticket
  alias BlockPoker.Tournaments.{BlindLevel, PayoutRow, Schedule}

  @type t :: %__MODULE__{}

  @currencies [:main, :play_money]
  @currency_order @currencies |> Enum.with_index() |> Map.new()
  @table_sizes [2, 6, 9]

  @editable [
    :name,
    :description,
    :game_type,
    :currency,
    :buy_in,
    :entry_fee,
    :starting_stack,
    :table_size,
    :min_players,
    :max_players,
    :max_entries,
    :rebuy_allowed,
    :rebuy_cost,
    :rebuy_stack,
    :max_rebuys,
    :addon_cost,
    :addon_stack,
    :guarantee,
    :bounty_part,
    :bounty_progressive,
    :bounty_split_ppm,
    :registration_opens_before,
    :cancel_refund_grace_seconds,
    :action_timeout_ms,
    :time_bank_ms,
    :time_bank_refill,
    :disconnect_grace_ms,
    :button_draw_animation_ms,
    :rebuy_prompt_ms,
    :felt_color,
    :background_color,
    :final_felt_color,
    :final_background_color,
    :enabled,
    :sort_order
  ]

  @color ~r/^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$/

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tournament_settings" do
    field :name, :string
    field :description, :string
    field :game_type, Ecto.Enum, values: VariantRegistry.ids()
    field :currency, Ecto.Enum, values: @currencies

    field :buy_in, :integer
    field :entry_fee, :integer, default: 0
    field :starting_stack, :integer

    field :table_size, :integer, default: 9
    field :min_players, :integer, default: 2
    field :max_players, :integer
    field :max_entries, :integer

    field :rebuy_allowed, :boolean, default: false
    field :rebuy_cost, :integer
    field :rebuy_stack, :integer
    field :max_rebuys, :integer

    field :addon_cost, :integer, default: 0
    field :addon_stack, :integer, default: 0

    field :guarantee, :integer, default: 0

    field :bounty_part, :integer, default: 0
    field :bounty_progressive, :boolean, default: true
    field :bounty_split_ppm, :integer, default: 500_000

    field :registration_opens_before, :integer, default: 3600
    field :cancel_refund_grace_seconds, :integer, default: 0

    field :action_timeout_ms, :integer, default: 15_000
    field :time_bank_ms, :integer, default: 20_000
    field :time_bank_refill, :integer, default: 5_000
    field :disconnect_grace_ms, :integer, default: 30_000
    field :button_draw_animation_ms, :integer, default: 3_000
    field :rebuy_prompt_ms, :integer, default: 30_000

    # Первая пара опознаёт **семейство** турнира и у каждого своя.
    # Вторая опознаёт **стадию** и одинакова во всей сетке: финальный
    # стол везде тёмно-золотой, и узнаётся он с одного взгляда — как бы
    # ни выглядел турнир, за которым игрок до него дошёл.
    field :felt_color, :string, default: "#1F4F7A"
    field :background_color, :string, default: "#0B1A2A"
    field :final_felt_color, :string, default: "#6B5518"
    field :final_background_color, :string, default: "#191206"

    field :enabled, :boolean, default: true
    field :sort_order, :integer, default: 0

    has_many :blind_levels, BlindLevel,
      foreign_key: :tournament_setting_id,
      preload_order: [asc: :level]

    has_many :payout_rows, PayoutRow,
      foreign_key: :tournament_setting_id,
      preload_order: [asc: :entries_from, asc: :place_from]

    has_many :schedules, Schedule, foreign_key: :tournament_setting_id
    has_many :tickets, Ticket, foreign_key: :tournament_setting_id

    # Снятый с сетки шаблон: строка остаётся ради истории и реплея, но
    # витрина её не видит и комнат под неё не поднимается. Не в `@editable`
    # — снимают и возвращают отдельным действием, а не правкой формы.
    field :archived_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @spec currencies() :: [atom()]
  def currencies, do: @currencies

  @spec table_sizes() :: [pos_integer()]
  def table_sizes, do: @table_sizes

  @doc "Полная цена входа — то, что игрок видит в витрине одним числом."
  @spec entry_price(t()) :: non_neg_integer()
  def entry_price(%__MODULE__{buy_in: buy_in, entry_fee: fee}), do: buy_in + fee

  @doc """
  Цена повторного входа. `nil` в шаблоне означает «как первичный вход» —
  это умолчание, а не отсутствие цены.
  """
  @spec reentry_price(t()) :: non_neg_integer()
  def reentry_price(%__MODULE__{rebuy_cost: nil} = setting), do: entry_price(setting)
  def reentry_price(%__MODULE__{rebuy_cost: cost}), do: cost

  @doc "Стек за повторный вход; `nil` означает стартовый."
  @spec reentry_stack(t()) :: pos_integer()
  def reentry_stack(%__MODULE__{rebuy_stack: nil, starting_stack: stack}), do: stack
  def reentry_stack(%__MODULE__{rebuy_stack: stack}), do: stack

  @doc """
  Как делится повторный вход на голову и призовую часть.

  Та же пропорция, что и у первичного взноса: иначе за столом оказались
  бы игроки с головой и без, и колл против них стоил бы разного при
  одинаковом стеке. Комиссия считается по доле от полной цены — она
  остаётся доходом рума и в фонд не попадает.
  """
  @spec reentry_split(t()) :: %{
          prize: non_neg_integer(),
          bounty: non_neg_integer(),
          fee: non_neg_integer()
        }
  def reentry_split(%__MODULE__{} = setting) do
    price = reentry_price(setting)
    full = entry_price(setting)

    if full == 0 do
      %{prize: 0, bounty: 0, fee: 0}
    else
      fee = div(price * setting.entry_fee, full)
      bounty = div(price * setting.bounty_part, full)
      %{prize: price - fee - bounty, bounty: bounty, fee: fee}
    end
  end

  @doc "Баунти-турнир? Единственный признак — ненулевая цена головы."
  @spec bounty?(t()) :: boolean()
  def bounty?(%__MODULE__{bounty_part: bounty_part}), do: bounty_part > 0

  @doc "Фриролл: вход бесплатен целиком, включая комиссию."
  @spec freeroll?(t()) :: boolean()
  def freeroll?(%__MODULE__{} = setting), do: entry_price(setting) == 0

  @doc """
  Признаки турнира для фильтров витрины. Вычисляются из шаблона, а не
  хранятся полями: хранимый флаг разошёлся бы с ценой на первой же правке.
  """
  @spec kinds(t()) :: [atom()]
  def kinds(%__MODULE__{} = setting) do
    []
    |> prepend_if(freeroll?(setting), :freeroll)
    |> prepend_if(setting.rebuy_allowed, :rebuy)
    |> prepend_if(bounty?(setting), :bounty)
    |> prepend_if(satellite?(setting), :satellite)
    |> Enum.reverse()
  end

  @doc "Саттелит — турнир, в выплатах которого есть билеты."
  @spec satellite?(t()) :: boolean()
  def satellite?(%__MODULE__{payout_rows: rows}) when is_list(rows) do
    Enum.any?(rows, &(&1.ticket_id != nil))
  end

  def satellite?(%__MODULE__{}), do: false

  @doc "Структура ставок задаётся видом покера, а не полем шаблона."
  @spec structure(t()) :: BettingStructure.t()
  def structure(%__MODULE__{game_type: game_type}) do
    game_type |> VariantRegistry.fetch!() |> then(& &1.betting_structure())
  end

  @doc """
  Ключ сортировки турнирной витрины. Валюта первым разрядом — как везде
  в руме; дальше порядок оператора, взнос и `id`, чтобы порядок был
  полным и не дрожал между запросами.
  """
  @spec sort_key(t()) :: tuple()
  def sort_key(%__MODULE__{} = setting) do
    {currency_rank(setting), setting.sort_order, entry_price(setting), setting.id}
  end

  @spec currency_rank(t()) :: non_neg_integer()
  def currency_rank(%__MODULE__{currency: currency}) do
    Map.get(@currency_order, currency, 99)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, @editable)
    |> validate_required([
      :game_type,
      :currency,
      :buy_in,
      :starting_stack,
      :table_size,
      :min_players,
      :max_players
    ])
    |> validate_inclusion(:table_size, @table_sizes)
    |> validate_number(:buy_in, greater_than_or_equal_to: 0)
    |> validate_number(:entry_fee, greater_than_or_equal_to: 0)
    |> validate_number(:starting_stack, greater_than: 0)
    |> validate_number(:min_players, greater_than_or_equal_to: 2)
    |> validate_number(:guarantee, greater_than_or_equal_to: 0)
    |> validate_number(:bounty_part, greater_than_or_equal_to: 0)
    |> validate_number(:bounty_split_ppm,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 1_000_000
    )
    |> validate_number(:registration_opens_before, greater_than: 0)
    |> validate_number(:cancel_refund_grace_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:sort_order, greater_than_or_equal_to: 0)
    |> validate_length(:name, max: 80)
    |> validate_length(:description, max: 500)
    |> validate_colors()
    |> validate_timings()
    |> validate_capacity()
    |> validate_bounty()
    |> validate_rebuy()
    |> validate_addon()
    |> unique_constraint([:name, :game_type, :currency, :buy_in, :table_size],
      name: :tournament_settings_natural_key
    )
    |> check_constraint(:table_size, name: :tournament_settings_seats)
    |> check_constraint(:buy_in, name: :tournament_settings_amounts)
    |> check_constraint(:bounty_part, name: :tournament_settings_bounty)
    |> check_constraint(:rebuy_cost, name: :tournament_settings_rebuy)
  end

  defp validate_capacity(changeset) do
    min = get_field(changeset, :min_players)
    max = get_field(changeset, :max_players)
    entries = get_field(changeset, :max_entries)

    changeset
    |> then(fn cs ->
      if is_integer(min) and is_integer(max) and max < min,
        do: add_error(cs, :max_players, "потолок игроков меньше порога старта"),
        else: cs
    end)
    |> then(fn cs ->
      # Потолок входов ниже порога старта означал бы турнир, который
      # нельзя начать: регистрация закроется раньше, чем наберётся минимум.
      if is_integer(entries) and is_integer(min) and entries < min,
        do: add_error(cs, :max_entries, "потолок входов ниже порога старта"),
        else: cs
    end)
  end

  # Голова берётся **из** взноса, а не сверх него. Фриролл с баунти
  # невозможен по построению: из нулевого взноса голову взять неоткуда.
  defp validate_bounty(changeset) do
    buy_in = get_field(changeset, :buy_in) || 0
    bounty = get_field(changeset, :bounty_part) || 0

    if bounty > buy_in do
      add_error(changeset, :bounty_part, "голова не может быть больше взноса")
    else
      changeset
    end
  end

  defp validate_rebuy(changeset) do
    changeset
    |> validate_number(:rebuy_cost, greater_than_or_equal_to: 0)
    |> validate_number(:rebuy_stack, greater_than: 0)
    |> validate_number(:max_rebuys, greater_than_or_equal_to: 0)
    |> then(fn cs ->
      # Цена и стек ре-энтри без разрешения на него — не ошибка данных,
      # а ошибка чтения: оператор думает, что ребаи включены, а они нет.
      if not get_field(cs, :rebuy_allowed) and get_field(cs, :max_rebuys) not in [nil, 0] do
        add_error(cs, :max_rebuys, "лимит ре-энтри задан, но ре-энтри запрещены")
      else
        cs
      end
    end)
  end

  defp validate_addon(changeset) do
    cost = get_field(changeset, :addon_cost) || 0
    stack = get_field(changeset, :addon_stack) || 0

    cond do
      cost < 0 -> add_error(changeset, :addon_cost, "цена аддона отрицательна")
      cost > 0 and stack <= 0 -> add_error(changeset, :addon_stack, "аддон без фишек")
      true -> changeset
    end
  end

  defp validate_colors(changeset) do
    Enum.reduce(
      [:felt_color, :background_color, :final_felt_color, :final_background_color],
      changeset,
      &validate_format(&2, &1, @color)
    )
  end

  defp validate_timings(changeset) do
    Enum.reduce(
      [
        :action_timeout_ms,
        :time_bank_ms,
        :time_bank_refill,
        :disconnect_grace_ms,
        :button_draw_animation_ms,
        :rebuy_prompt_ms
      ],
      changeset,
      &validate_number(&2, &1, greater_than_or_equal_to: 0)
    )
  end

  defp prepend_if(list, false, _value), do: list
  defp prepend_if(list, true, value), do: [value | list]
end
