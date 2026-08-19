defmodule BlockPoker.CashGames.CashGameSetting do
  @moduledoc """
  Шаблон кэш-игры: строка в БД, из которой разворачивается пул живых комнат.

  Шаблон — это *описание лимита*, а не стол. Столов (комнат) под одним
  шаблоном может быть сколько угодно, и они процессы (§3 задачи 3).

  Бай-ин хранится в **больших блайндах**, а не в фишках: `min: 40, max: 100` —
  это классический стол на 100bb, и такая запись переживает смену лимитов.
  Абсолютные значения считаются от `big_blind` функциями `min_buy_in_chips/1`
  и `max_buy_in_chips/1` — арифметика над фишками живёт в ядре, не во view.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BlockPoker.Engine.Variant.Registry, as: VariantRegistry

  @type t :: %__MODULE__{}

  @currencies [:main, :play_money]
  @ante_types [:big_blind, :per_player]
  @visibilities [:public, :private]

  @editable [
    :name,
    :game_type,
    :currency,
    :small_blind,
    :big_blind,
    :ante,
    :ante_type,
    :max_players,
    :min_buy_in,
    :max_buy_in,
    :rake_percent,
    :rake_cap_by_players,
    :no_flop_no_drop,
    :action_timeout_ms,
    :time_bank_ms,
    :time_bank_refill,
    :disconnect_grace_ms,
    :sit_out_max_hands,
    :rebuy_prompt_ms,
    :button_draw_animation_ms,
    :allow_post_blind,
    :auto_start,
    :blind_dodge_window_hands,
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
  schema "cash_game_settings" do
    field :name, :string
    field :game_type, Ecto.Enum, values: VariantRegistry.ids()
    field :currency, Ecto.Enum, values: @currencies

    field :small_blind, :integer
    field :big_blind, :integer
    field :ante, :integer, default: 0
    field :ante_type, Ecto.Enum, values: @ante_types, default: :big_blind
    field :max_players, :integer

    field :min_buy_in, :integer, default: 40
    field :max_buy_in, :integer

    field :rake_percent, :integer, default: 0
    field :rake_cap_by_players, :map, default: %{}
    field :no_flop_no_drop, :boolean, default: true

    field :action_timeout_ms, :integer, default: 20_000
    field :time_bank_ms, :integer, default: 30_000
    field :time_bank_refill, :integer, default: 10_000
    field :disconnect_grace_ms, :integer, default: 30_000
    field :sit_out_max_hands, :integer, default: 20
    field :rebuy_prompt_ms, :integer, default: 60_000
    field :button_draw_animation_ms, :integer, default: 3_000

    field :allow_post_blind, :boolean, default: true

    # Стол с `false` сам не стартует, даже когда за ним собрался полный состав:
    # первую раздачу запускает администратор командой `start_game`. Дальше
    # раздачи идут обычным порядком.
    field :auto_start, :boolean, default: true
    field :blind_dodge_window_hands, :integer, default: 10

    # Косметика стола: цвет сукна и цвет фона комнаты. Сервер их только хранит
    # и отдаёт клиенту — на правила они не влияют.
    field :felt_color, :string, default: "#1F6F4A"
    field :background_color, :string, default: "#10241C"

    field :enabled, :boolean, default: true
    field :visibility, Ecto.Enum, values: @visibilities, default: :public
    field :sort_order, :integer, default: 0
    field :max_rooms, :integer, default: 100

    timestamps(type: :utc_datetime_usec)
  end

  @spec currencies() :: [atom()]
  def currencies, do: @currencies

  @spec ante_types() :: [atom()]
  def ante_types, do: @ante_types

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, @editable)
    |> validate_required([:game_type, :currency, :small_blind, :big_blind, :max_players])
    |> validate_number(:small_blind, greater_than: 0)
    |> validate_number(:ante, greater_than_or_equal_to: 0)
    |> validate_inclusion(:max_players, 2..9)
    |> validate_number(:min_buy_in, greater_than_or_equal_to: 20)
    |> validate_inclusion(:rake_percent, 0..1000)
    |> validate_number(:sort_order, greater_than_or_equal_to: 0)
    |> validate_number(:max_rooms, greater_than: 0)
    |> validate_length(:name, max: 80)
    |> validate_format(:felt_color, @color)
    |> validate_format(:background_color, @color)
    |> validate_timings()
    |> validate_blinds()
    |> validate_buy_in()
    |> validate_rake_caps()
    |> unique_constraint(
      [:game_type, :currency, :small_blind, :big_blind, :ante, :max_players],
      name: :cash_game_settings_natural_key
    )
  end

  @doc "Нижняя граница бай-ина в фишках."
  @spec min_buy_in_chips(t()) :: pos_integer()
  def min_buy_in_chips(%__MODULE__{} = setting), do: setting.min_buy_in * setting.big_blind

  @doc "Верхняя граница бай-ина в фишках; `nil` — стол без потолка."
  @spec max_buy_in_chips(t()) :: pos_integer() | nil
  def max_buy_in_chips(%__MODULE__{max_buy_in: nil}), do: nil
  def max_buy_in_chips(%__MODULE__{} = setting), do: setting.max_buy_in * setting.big_blind

  @doc """
  Потолок рейка для раздачи с `players` участниками: берётся ближайший
  меньший ключ. Пустая карта означает «потолка нет».
  """
  @spec rake_cap(t(), pos_integer()) :: pos_integer() | nil
  def rake_cap(%__MODULE__{rake_cap_by_players: caps}, players) when is_map(caps) do
    caps
    |> Enum.map(fn {key, value} -> {to_int(key), value} end)
    |> Enum.filter(fn {key, _value} -> is_integer(key) and key <= players end)
    |> Enum.max_by(fn {key, _value} -> key end, fn -> nil end)
    |> case do
      nil -> nil
      {_key, value} -> value
    end
  end

  @doc "Название для лобби: явное имя шаблона либо производное от лимитов."
  @spec display_name(t()) :: String.t()
  def display_name(%__MODULE__{name: name}) when is_binary(name) and name != "", do: name

  def display_name(%__MODULE__{} = setting) do
    "#{setting.small_blind}/#{setting.big_blind} #{setting.max_players}-max"
  end

  defp validate_blinds(changeset) do
    small = get_field(changeset, :small_blind)
    big = get_field(changeset, :big_blind)

    if is_integer(small) and is_integer(big) and big <= small do
      add_error(changeset, :big_blind, "должен быть больше малого блайнда")
    else
      changeset
    end
  end

  defp validate_buy_in(changeset) do
    min = get_field(changeset, :min_buy_in)
    max = get_field(changeset, :max_buy_in)

    if is_integer(max) and is_integer(min) and max < min do
      add_error(changeset, :max_buy_in, "не может быть меньше минимального бай-ина")
    else
      changeset
    end
  end

  defp validate_timings(changeset) do
    positive = [
      :action_timeout_ms,
      :disconnect_grace_ms,
      :rebuy_prompt_ms,
      :sit_out_max_hands,
      :blind_dodge_window_hands
    ]

    changeset =
      Enum.reduce(positive, changeset, fn field, acc ->
        validate_number(acc, field, greater_than: 0)
      end)

    Enum.reduce([:time_bank_ms, :time_bank_refill, :button_draw_animation_ms], changeset, fn
      field, acc -> validate_number(acc, field, greater_than_or_equal_to: 0)
    end)
  end

  defp validate_rake_caps(changeset) do
    caps = get_field(changeset, :rake_cap_by_players) || %{}
    max_players = get_field(changeset, :max_players)

    cond do
      not is_map(caps) ->
        add_error(changeset, :rake_cap_by_players, "должен быть картой игроки-потолок")

      caps == %{} ->
        changeset

      true ->
        validate_filled_caps(changeset, caps, max_players)
    end
  end

  defp validate_filled_caps(changeset, caps, max_players) do
    pairs = Enum.map(caps, fn {key, value} -> {to_int(key), value} end)

    cond do
      Enum.any?(pairs, fn {key, _} -> not (is_integer(key) and key in 2..(max_players || 9)) end) ->
        add_error(changeset, :rake_cap_by_players, "ключи — число игроков от 2 до max_players")

      Enum.any?(pairs, fn {_, value} -> not (is_integer(value) and value >= 0) end) ->
        add_error(changeset, :rake_cap_by_players, "потолок задаётся неотрицательным целым")

      not Enum.any?(pairs, fn {key, _} -> key == 2 end) ->
        add_error(changeset, :rake_cap_by_players, "обязателен ключ 2 (хедз-ап)")

      true ->
        put_change(
          changeset,
          :rake_cap_by_players,
          Map.new(pairs, fn {key, value} -> {to_string(key), value} end)
        )
    end
  end

  defp to_int(key) when is_integer(key), do: key

  defp to_int(key) when is_binary(key) do
    case Integer.parse(key) do
      {value, ""} -> value
      _other -> nil
    end
  end

  defp to_int(_key), do: nil
end
