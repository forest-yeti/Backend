defmodule BlockPoker.SitAndGo.SitAndGoSetting do
  @moduledoc """
  Шаблон Sit & Go: строка в БД, из которой разворачивается пул турниров.

  Как и шаблон кэша, это *описание условий*, а не стол: под одним шаблоном
  живёт сколько угодно одновременных турниров, и каждый — процесс. Отличий
  от кэша три, и все следуют из того, что турнир конечен.

    * **Пул точный, а не минимальный.** `max_players` — это и вместимость,
      и условие старта: 3-max начинается тройкой, 6-max шестёркой. «Играть
      вчетвером за столом на шесть» в Sit & Go не бывает.
    * **Взнос один и фиксированный.** Границ бай-ина нет: все входят
      одинаково, иначе стартовые стеки были бы разными и структура мест
      потеряла бы смысл.
    * **Номиналы приходят из структуры уровней** (`sit_n_go_blind_levels`),
      а не из полей шаблона: они растут по ходу турнира.

  Рейка в шаблоне нет намеренно. Банк за турнирным столом — фишки, а не
  деньги, и брать с него процент нечего; доход рума вшит в матожидание
  таблицы призов (`Engine.PrizePool`) и живёт там, где его можно проверить
  тестом.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BlockPoker.Engine.BettingStructure
  alias BlockPoker.Engine.Variant.Registry, as: VariantRegistry
  alias BlockPoker.SitAndGo.{BlindLevel, PrizeTier}

  @type t :: %__MODULE__{}

  # Порядок валют фиксирован и задаёт разделы витрины: реальные деньги
  # выше игровых. То же правило действует в кэше (`Tables.LobbyQuery`),
  # и разъезжаться им нельзя — игрок видит один рум, а не два списка
  # с разной логикой.
  @currencies [:main, :play_money]
  @currency_order @currencies |> Enum.with_index() |> Map.new()

  @editable [
    :name,
    :game_type,
    :currency,
    :max_players,
    :buy_in,
    :starting_stack,
    :action_timeout_ms,
    :time_bank_ms,
    :time_bank_refill,
    :disconnect_grace_ms,
    :button_draw_animation_ms,
    :prize_reveal_ms,
    :felt_color,
    :background_color,
    :enabled,
    :sort_order,
    :max_rooms
  ]

  @color ~r/^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$/

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "sit_n_go_settings" do
    field :name, :string
    field :game_type, Ecto.Enum, values: VariantRegistry.ids()
    field :currency, Ecto.Enum, values: @currencies

    field :max_players, :integer

    field :buy_in, :integer
    field :starting_stack, :integer

    field :action_timeout_ms, :integer, default: 15_000
    field :time_bank_ms, :integer, default: 20_000
    field :time_bank_refill, :integer, default: 5_000
    field :disconnect_grace_ms, :integer, default: 30_000
    field :button_draw_animation_ms, :integer, default: 3_000
    field :prize_reveal_ms, :integer, default: 5_000

    # Золотой антураж — признак режима, а не украшение строки: кэш зелёный,
    # Sit & Go золотой, и стол опознаётся с одного взгляда. Золото
    # приглушённое: на ярком фоне белые карты и светлые фишки теряются.
    field :felt_color, :string, default: "#9A7A2E"
    field :background_color, :string, default: "#151006"

    field :enabled, :boolean, default: true
    field :sort_order, :integer, default: 0
    field :max_rooms, :integer, default: 100

    has_many :blind_levels, BlindLevel,
      foreign_key: :sit_n_go_setting_id,
      preload_order: [asc: :level]

    has_many :prize_tiers, PrizeTier,
      foreign_key: :sit_n_go_setting_id,
      preload_order: [desc: :chance_ppm]

    # Снятый с сетки шаблон: строка остаётся ради истории и реплея, но
    # витрина её не видит и комнат под неё не поднимается. Не в `@editable`
    # — снимают и возвращают отдельным действием, а не правкой формы.
    field :archived_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @spec currencies() :: [atom()]
  def currencies, do: @currencies

  @doc """
  Ключ сортировки витрины — единственное правило порядка турниров.

  Валюта первым разрядом: сперва весь раздел на реальные деньги, потом
  игровые. Дальше — порядок оператора, взнос и рассадка; `id` замыкает,
  чтобы порядок был полным и не «дрожал» между запросами при равенстве
  всех прочих полей.
  """
  @spec sort_key(t()) :: tuple()
  def sort_key(%__MODULE__{} = setting) do
    {currency_rank(setting), setting.sort_order, setting.buy_in, setting.max_players, setting.id}
  end

  @doc "Разряд валюты: чем меньше, тем выше в витрине."
  @spec currency_rank(t()) :: non_neg_integer()
  def currency_rank(%__MODULE__{currency: currency}) do
    # Неизвестная валюта уезжает в конец, а не роняет сортировку: список
    # валют может вырасти раньше, чем это правило.
    Map.get(@currency_order, currency, 99)
  end

  @doc """
  Структура ставок турнира. Как и в кэше, её задаёт вид покера, а не поле:
  холдем — блайнды, Short Deck — анте кнопки.
  """
  @spec structure(t()) :: BettingStructure.t()
  def structure(%__MODULE__{game_type: game_type}) do
    game_type |> VariantRegistry.fetch!() |> then(& &1.betting_structure())
  end

  @doc """
  Суммарные фишки турнира: столько их за столом от первой раздачи до
  последней. Инвариант «турнирные фишки не создаются и не исчезают»
  проверяется относительно этого числа.
  """
  @spec total_chips(t()) :: pos_integer()
  def total_chips(%__MODULE__{} = setting), do: setting.max_players * setting.starting_stack

  @doc """
  Сумма взносов турнира — то, из чего рум платит призы и оставляет свою долю.
  Деньгами она становится один раз, на регистрации, и больше не двигается.
  """
  @spec total_buy_in(t()) :: pos_integer()
  def total_buy_in(%__MODULE__{} = setting), do: setting.max_players * setting.buy_in

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, @editable)
    |> validate_required([:game_type, :currency, :max_players, :buy_in, :starting_stack])
    |> validate_inclusion(:max_players, 2..9)
    |> validate_number(:buy_in, greater_than: 0)
    |> validate_number(:starting_stack, greater_than: 0)
    |> validate_number(:sort_order, greater_than_or_equal_to: 0)
    |> validate_number(:max_rooms, greater_than: 0)
    |> validate_length(:name, max: 80)
    |> validate_format(:felt_color, @color)
    |> validate_format(:background_color, @color)
    |> validate_timings()
    |> unique_constraint([:game_type, :currency, :buy_in, :max_players],
      name: :sit_n_go_settings_natural_key
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
        :prize_reveal_ms
      ],
      changeset,
      &validate_number(&2, &1, greater_than_or_equal_to: 0)
    )
  end
end
