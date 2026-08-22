defmodule BlockPoker.OfcGames.OfcSetting do
  @moduledoc """
  Шаблон стола китайского покера: строка в БД, из которой разворачивается пул
  живых комнат.

  Своя таблица, а не колонка `discipline` в `cash_game_settings`. Причина в
  том, что у дисциплины без банка нет половины полей кэша: блайндов, анте,
  рейка, бомб-пота, двух прогонов и взноса за вход. Держать их пустыми в
  каждой строке — это поля, которые никогда не читаются, и валидация вместо
  отсутствия колонки.

  Базовая единица стола здесь — **стоимость очка**: в ней считается бай-ин и
  в ней же лобби показывает лимит. Отвечает на тот же вопрос, что большой
  блайнд у блайндового стола, поэтому ветвления в снапшоте не появляется.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BlockPoker.CashGames.CashGameSetting
  alias BlockPoker.Engine.Variant.Registry, as: VariantRegistry

  @type t :: %__MODULE__{}

  @currencies [:main, :play_money]
  @visibilities [:public, :private]

  # Полная колода обязательна: ананасу нужны 52 карты, и Short Deck с ним
  # не сочетается. Запрет живёт списком допустимых видов, а не проверкой
  # «не Short Deck»: новый короткий вариант не должен пролезть молча.
  @game_types [:texas_holdem]

  @editable [
    :name,
    :code,
    :game_type,
    :currency,
    :point_value,
    :max_players,
    :min_buy_in,
    :max_buy_in,
    :action_timeout_ms,
    :time_bank_ms,
    :time_bank_refill,
    :disconnect_grace_ms,
    :sit_out_timeout_ms,
    :rebuy_prompt_ms,
    :button_draw_animation_ms,
    :auto_start,
    :felt_color,
    :background_color,
    :enabled,
    :visibility,
    :sort_order,
    :max_rooms
  ]

  @color ~r/^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$/

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "ofc_settings" do
    field :name, :string
    field :game_type, Ecto.Enum, values: @game_types, default: :texas_holdem
    field :currency, Ecto.Enum, values: @currencies

    field :point_value, :integer
    field :max_players, :integer, default: 3

    field :min_buy_in, :integer, default: 50
    field :max_buy_in, :integer, default: 200

    field :action_timeout_ms, :integer, default: 30_000
    field :time_bank_ms, :integer, default: 60_000
    field :time_bank_refill, :integer, default: 15_000
    field :disconnect_grace_ms, :integer, default: 30_000
    field :sit_out_timeout_ms, :integer, default: 300_000
    field :rebuy_prompt_ms, :integer, default: 60_000
    field :button_draw_animation_ms, :integer, default: 3_000

    field :auto_start, :boolean, default: true

    field :felt_color, :string, default: "#1F6F4A"
    field :background_color, :string, default: "#10241C"

    field :enabled, :boolean, default: true
    field :visibility, Ecto.Enum, values: @visibilities, default: :public
    field :code, :string
    field :sort_order, :integer, default: 0
    field :max_rooms, :integer, default: 100

    timestamps(type: :utc_datetime_usec)
  end

  @spec currencies() :: [atom()]
  def currencies, do: @currencies

  @spec game_types() :: [atom()]
  def game_types, do: @game_types

  @spec visibilities() :: [atom()]
  def visibilities, do: @visibilities

  @doc """
  Базовая единица стола — стоимость очка. Отвечает на тот же вопрос, что
  большой блайнд у блайндового стола: от чего считать бай-ин и лимит.
  """
  @spec bet_unit(t()) :: pos_integer()
  def bet_unit(%__MODULE__{point_value: point_value}), do: point_value

  @spec min_buy_in_chips(t()) :: pos_integer()
  def min_buy_in_chips(%__MODULE__{} = setting), do: setting.min_buy_in * bet_unit(setting)

  @doc "Верхняя граница бай-ина в фишках; `nil` — стол без потолка."
  @spec max_buy_in_chips(t()) :: pos_integer() | nil
  def max_buy_in_chips(%__MODULE__{max_buy_in: nil}), do: nil
  def max_buy_in_chips(%__MODULE__{} = setting), do: setting.max_buy_in * bet_unit(setting)

  @doc "Видна ли комната в общей сетке лобби."
  @spec public?(t()) :: boolean()
  def public?(%__MODULE__{visibility: :private}), do: false
  def public?(%__MODULE__{}), do: true

  @doc """
  Сколько комнат разворачивает шаблон. У закрытого — ровно одна: код ведёт
  друзей за один и тот же стол, а не за случайный из пула.
  """
  @spec room_limit(t()) :: pos_integer()
  def room_limit(%__MODULE__{} = setting) do
    if public?(setting), do: setting.max_rooms, else: 1
  end

  @doc """
  Код входа закрытой комнаты. Правила кода общие с кэшем: тот же алфавит,
  та же длина, тот же источник случайности — второй их копии в кодовой базе
  быть не должно.
  """
  @spec generate_code() :: String.t()
  defdelegate generate_code(), to: CashGameSetting

  @spec normalize_code(term()) :: String.t() | nil
  defdelegate normalize_code(code), to: CashGameSetting

  @spec valid_code?(term()) :: boolean()
  defdelegate valid_code?(code), to: CashGameSetting

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, @editable)
    |> validate_required([:game_type, :currency, :point_value, :max_players])
    |> validate_inclusion(:game_type, @game_types)
    # Ананас держит троих впритык: 3 × 17 = 51 карта из 52. Ограничение
    # принадлежит дисциплине, а не шаблону, поэтому и берётся у неё.
    |> validate_inclusion(:max_players, discipline_players())
    |> validate_number(:point_value, greater_than: 0)
    |> validate_number(:min_buy_in, greater_than: 0)
    |> validate_number(:sort_order, greater_than_or_equal_to: 0)
    |> validate_number(:max_rooms, greater_than: 0)
    |> validate_length(:name, max: 80)
    |> validate_format(:felt_color, @color)
    |> validate_format(:background_color, @color)
    |> validate_code()
    |> validate_timings()
    |> validate_buy_in()
    |> unique_constraint([:currency, :point_value, :max_players],
      name: :ofc_settings_natural_key
    )
    |> unique_constraint(:code, name: :ofc_settings_code_index)
  end

  defp discipline_players do
    discipline = BlockPoker.Engine.Ofc.Hand
    discipline.min_players()..discipline.max_players()
  end

  defp validate_buy_in(changeset) do
    min = get_field(changeset, :min_buy_in)
    max = get_field(changeset, :max_buy_in)

    if is_integer(min) and is_integer(max) and max < min do
      add_error(changeset, :max_buy_in, "меньше минимального бай-ина")
    else
      changeset
    end
  end

  defp validate_timings(changeset) do
    Enum.reduce(
      [
        :action_timeout_ms,
        :time_bank_ms,
        :time_bank_refill,
        :disconnect_grace_ms,
        :sit_out_timeout_ms,
        :rebuy_prompt_ms,
        :button_draw_animation_ms
      ],
      changeset,
      &validate_number(&2, &1, greater_than_or_equal_to: 0)
    )
  end

  # Закрытая комната обязана иметь код, публичная — не иметь: код и есть
  # единственный способ за неё сесть.
  defp validate_code(changeset) do
    code = changeset |> get_field(:code) |> normalize_code()

    case get_field(changeset, :visibility) do
      :private when is_binary(code) ->
        if valid_code?(code) do
          put_change(changeset, :code, code)
        else
          add_error(changeset, :code, "неверный формат кода")
        end

      :private ->
        add_error(changeset, :code, "закрытая комната без кода")

      _public ->
        put_change(changeset, :code, nil)
    end
  end

  @doc "Вариант покера шаблона — по нему собирается колода и роспись пятёрки."
  @spec variant(t()) :: module()
  def variant(%__MODULE__{game_type: game_type}), do: VariantRegistry.fetch!(game_type)
end
