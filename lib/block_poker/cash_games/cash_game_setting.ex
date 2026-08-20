defmodule BlockPoker.CashGames.CashGameSetting do
  @moduledoc """
  Шаблон кэш-игры: строка в БД, из которой разворачивается пул живых комнат.

  Шаблон — это *описание лимита*, а не стол. Столов (комнат) под одним
  шаблоном может быть сколько угодно, и они процессы (§3 задачи 3).

  Бай-ин хранится в **базовых единицах стола**, а не в фишках: `min: 40,
  max: 100` — это классический стол на 100 единиц, и такая запись переживает
  смену лимитов. Базовая единица зависит от структуры ставок (`bet_unit/1`):
  на блайндовом столе это большой блайнд, на анте-столе — анте. Абсолютные
  значения считают `min_buy_in_chips/1` и `max_buy_in_chips/1` — арифметика
  над фишками живёт в ядре, не во view.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BlockPoker.Engine.BettingStructure
  alias BlockPoker.Engine.Variant.Registry, as: VariantRegistry

  @type t :: %__MODULE__{}

  @currencies [:main, :play_money]
  @ante_types [:big_blind, :per_player]
  @visibilities [:public, :private]

  @editable [
    :name,
    :code,
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
    :sit_out_timeout_ms,
    :rebuy_prompt_ms,
    :button_draw_animation_ms,
    :allow_post_blind,
    :auto_start,
    :allowed_run_it_twice,
    :blind_dodge_window_hands,
    :felt_color,
    :background_color,
    :enabled,
    :visibility,
    :sort_order,
    :max_rooms
  ]

  @color ~r/^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$/

  # Алфавит кода: строчная латиница и цифры без пар, которые путают при
  # диктовке вслух и переписывании от руки (0/o, 1/l/i).
  @code_alphabet ~c"abcdefghjkmnpqrstuvwxyz23456789"
  @code_length 6
  @code_format ~r/^[a-z0-9]{6}$/

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

    # Сколько игрок вправе просидеть в паузе, прежде чем стол вернёт ему
    # фишки и освободит место. Единица — время, а не раздачи: длительность
    # раздачи зависит от числа игроков, а договаривается игрок в минутах.
    field :sit_out_timeout_ms, :integer, default: 300_000
    field :rebuy_prompt_ms, :integer, default: 60_000
    field :button_draw_animation_ms, :integer, default: 3_000

    field :allow_post_blind, :boolean, default: true

    # Двое в олл-ине могут договориться разыграть недостающие улицы дважды.
    # Флаг живёт в шаблоне кэша, потому что это функция кэш-игры: в турнирах
    # она выключена всегда и настройкой не управляется (§3.1 задачи 5).
    field :allowed_run_it_twice, :boolean, default: true

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

    # `:private` — шаблона нет в общей сетке лобби, войти можно только по коду.
    field :visibility, Ecto.Enum, values: @visibilities, default: :public

    # Код входа закрытой комнаты. У публичных шаблонов — `nil`; уникален
    # среди заданных (в MySQL `NULL` уникальному индексу не мешает).
    field :code, :string
    field :sort_order, :integer, default: 0
    field :max_rooms, :integer, default: 100

    timestamps(type: :utc_datetime_usec)
  end

  @spec currencies() :: [atom()]
  def currencies, do: @currencies

  @spec ante_types() :: [atom()]
  def ante_types, do: @ante_types

  @doc """
  Структура ставок стола. Её задаёт вид покера, а не отдельное поле: холдем
  играется на блайндах, Short Deck — на анте кнопки.
  """
  @spec structure(t()) :: BettingStructure.t()
  def structure(%__MODULE__{game_type: game_type}) do
    game_type |> VariantRegistry.fetch!() |> then(& &1.betting_structure())
  end

  @doc """
  Базовая единица стола: большой блайнд у блайндов, анте у анте кнопки.
  В ней же считается бай-ин и категория лимита в лобби.
  """
  @spec bet_unit(t()) :: non_neg_integer()
  def bet_unit(%__MODULE__{} = setting) do
    structure(setting).bet_unit(%{big_blind: setting.big_blind, ante: setting.ante})
  end

  @spec visibilities() :: [atom()]
  def visibilities, do: @visibilities

  @spec code_length() :: pos_integer()
  def code_length, do: @code_length

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
  Приведение кода к каноническому виду: регистр и пробелы игроку прощаются,
  в базе код всегда в нижнем регистре.
  """
  @spec normalize_code(term()) :: String.t() | nil
  def normalize_code(code) when is_binary(code) do
    case code |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  def normalize_code(_code), do: nil

  @doc "Проверка формы кода — до похода в базу."
  @spec valid_code?(term()) :: boolean()
  def valid_code?(code) do
    case normalize_code(code) do
      nil -> false
      normalized -> Regex.match?(@code_format, normalized)
    end
  end

  @doc """
  Новый код входа. Источник случайности — `:crypto.strong_rand_bytes/1`:
  угадываемый код пускает за закрытый стол постороннего (§9 CLAUDE.md).
  Столкновение отсекает UNIQUE-индекс, а не проверка перед вставкой.
  """
  @spec generate_code() :: String.t()
  def generate_code do
    size = length(@code_alphabet)

    @code_length
    |> :crypto.strong_rand_bytes()
    |> :binary.bin_to_list()
    |> Enum.map_join(fn byte -> <<Enum.at(@code_alphabet, rem(byte, size))>> end)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, @editable)
    |> validate_required([:game_type, :currency, :small_blind, :big_blind, :max_players])
    |> validate_number(:small_blind, greater_than_or_equal_to: 0)
    |> validate_number(:ante, greater_than_or_equal_to: 0)
    |> validate_inclusion(:max_players, 2..9)
    |> validate_number(:min_buy_in, greater_than_or_equal_to: 20)
    |> validate_inclusion(:rake_percent, 0..1000)
    |> validate_number(:sort_order, greater_than_or_equal_to: 0)
    |> validate_number(:max_rooms, greater_than: 0)
    |> validate_length(:name, max: 80)
    |> validate_code()
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
    |> unique_constraint(:code, name: :cash_game_settings_code)
  end

  @doc "Нижняя граница бай-ина в фишках."
  @spec min_buy_in_chips(t()) :: pos_integer()
  def min_buy_in_chips(%__MODULE__{} = setting), do: setting.min_buy_in * bet_unit(setting)

  @doc "Верхняя граница бай-ина в фишках; `nil` — стол без потолка."
  @spec max_buy_in_chips(t()) :: pos_integer() | nil
  def max_buy_in_chips(%__MODULE__{max_buy_in: nil}), do: nil
  def max_buy_in_chips(%__MODULE__{} = setting), do: setting.max_buy_in * bet_unit(setting)

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

  defp validate_code(changeset) do
    changeset
    |> update_change(:code, &normalize_code/1)
    |> validate_format(:code, @code_format,
      message: "допустимы #{@code_length} символов: строчная латиница и цифры"
    )
  end

  # Какие номиналы шаблон обязан заполнить, решает структура ставок, а не
  # `game_type`: блайндовому столу нужны блайнды, анте-столу — анте, и лишние
  # поля у обоих должны быть нулями, иначе в БД поселится второй, никем не
  # применяемый лимит.
  defp validate_blinds(changeset) do
    case structure_of(changeset) do
      nil -> changeset
      BettingStructure.Blinds -> validate_blind_limits(changeset)
      _button_ante -> validate_ante_limits(changeset)
    end
  end

  defp structure_of(changeset) do
    case VariantRegistry.fetch(get_field(changeset, :game_type)) do
      {:ok, variant} -> variant.betting_structure()
      {:error, :unknown_variant} -> nil
    end
  end

  defp validate_blind_limits(changeset) do
    small = get_field(changeset, :small_blind)
    big = get_field(changeset, :big_blind)

    changeset
    |> require_positive(:small_blind, "на блайндовом столе нужны блайнды")
    |> then(fn changeset ->
      if is_integer(small) and is_integer(big) and big <= small do
        add_error(changeset, :big_blind, "должен быть больше малого блайнда")
      else
        changeset
      end
    end)
  end

  # Проверяем по `get_field/2`, а не `validate_number/3`: у `ante` в схеме
  # дефолт 0, и явно переданный ноль изменением не считается — валидация
  # числа его просто не увидела бы.
  defp validate_ante_limits(changeset) do
    changeset
    |> require_positive(:ante, "на анте-столе нужен номинал больше нуля")
    |> require_zero(:small_blind, "на анте-столе блайндов нет")
    |> require_zero(:big_blind, "на анте-столе блайндов нет")
  end

  defp require_positive(changeset, field, message) do
    if is_integer(get_field(changeset, field)) and get_field(changeset, field) > 0 do
      changeset
    else
      add_error(changeset, field, message)
    end
  end

  defp require_zero(changeset, field, message) do
    case get_field(changeset, field) do
      value when value in [0, nil] -> changeset
      _other -> add_error(changeset, field, message)
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
      :sit_out_timeout_ms,
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
