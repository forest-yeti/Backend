defmodule BlockPoker.Tournaments.TableSetting do
  @moduledoc """
  Настройки **одного стола** турнира: то, что `TableServer` читает вместо
  шаблона.

  Существует потому, что у турнира и стола разное «сколько игроков».
  У шаблона `max_players` — это потолок участников турнира (сотни),
  у стола — вместимость (`table_size`, два-шесть-девять). Комната
  разворачивает мест ровно `setting.max_players`, и подсунуть ей шаблон
  турнира значило бы поднять стол на триста мест.

  Здесь же снимается вторая проблема: **стол не должен ходить в БД за
  шаблоном.** Инстанс турнира снял снапшот при открытии регистрации
  (§9 задачи), и стол получает копию уже из него — правка структуры
  оператором не поднимет блайнды посреди раздачи.

  Третье, что живёт здесь, — **признак финального стола**. Он не
  настройка комнаты, а событие турнира: когда выжившие собираются за
  одним столом, `TournamentServer` пересобирает его настройки со второй
  парой цветов. Клиент цвет не выбирает и не хранит — он приходит
  в снапшоте, как в кэше.
  """

  alias BlockPoker.Engine.BlindSchedule

  @type t :: %__MODULE__{}

  @enforce_keys [:id, :tournament_id, :max_players, :game_type, :currency, :starting_stack]
  defstruct [
    # `id` — идентификатор **шаблона** турнира: под ним стол известен
    # витрине и истории раздач. Комната кладёт его в снапшот как
    # `setting_id`, и турнирный стол не должен выглядеть беспризорным.
    :id,
    :tournament_id,
    :name,
    :game_type,
    :currency,
    :max_players,
    :starting_stack,
    # Взнос показывается в снапшоте стола рядом со стеком. Здесь это
    # полная цена входа: игроку за столом не нужно раскладывать её на
    # взнос и комиссию, ему нужно знать, во что он играет.
    buy_in: 0,
    action_timeout_ms: 15_000,
    time_bank_ms: 20_000,
    time_bank_refill: 5_000,
    disconnect_grace_ms: 30_000,
    button_draw_animation_ms: 3_000,
    rebuy_prompt_ms: 30_000,
    felt_color: "#1F4F7A",
    background_color: "#0B1A2A",
    # Структура уровней турнира целиком: стол применяет тот уровень,
    # который назвал турнир, и сам номиналы не выбирает.
    levels: [],
    # Цена головы за вход — для баунти-турниров. Ноль означает, что
    # голов в этом турнире нет вовсе.
    bounty_part: 0,
    final?: false
  ]

  @doc """
  Собирает настройки стола из снапшота инстанса.

  Читается снапшот, а не шаблон: в этом и смысл снапшота. Ключи
  строковые, потому что это JSON из БД.
  """
  @spec from_snapshot(map(), Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: t()
  def from_snapshot(snapshot, setting_id, tournament_id, opts \\ []) do
    %__MODULE__{
      id: setting_id,
      tournament_id: tournament_id,
      name: Keyword.get(opts, :name, snapshot["name"] || "Турнир"),
      game_type: String.to_existing_atom(snapshot["game_type"]),
      currency: String.to_existing_atom(snapshot["currency"]),
      max_players: snapshot["table_size"],
      starting_stack: snapshot["starting_stack"],
      buy_in: snapshot["buy_in"] + snapshot["entry_fee"],
      action_timeout_ms: Keyword.get(opts, :action_timeout_ms, 15_000),
      time_bank_ms: Keyword.get(opts, :time_bank_ms, 20_000),
      time_bank_refill: Keyword.get(opts, :time_bank_refill, 5_000),
      disconnect_grace_ms: Keyword.get(opts, :disconnect_grace_ms, 30_000),
      button_draw_animation_ms: Keyword.get(opts, :button_draw_animation_ms, 3_000),
      rebuy_prompt_ms: Keyword.get(opts, :rebuy_prompt_ms, 30_000),
      felt_color: Keyword.get(opts, :felt_color, "#1F4F7A"),
      background_color: Keyword.get(opts, :background_color, "#0B1A2A"),
      levels: levels(snapshot),
      bounty_part: snapshot["bounty_part"] || 0,
      final?: Keyword.get(opts, :final?, false)
    }
  end

  @doc """
  Расписание уровней в виде, который читает `Engine.BlindSchedule`.

  Флаги входа (`rebuy_allowed`, `addon_allowed`) сюда не попадают: они
  про регистрацию, а не про номиналы, и решает по ним турнир, а не стол.
  """
  @spec levels(map()) :: [BlindSchedule.level()]
  def levels(%{"levels" => levels}) when is_list(levels) do
    levels
    |> Enum.map(fn level ->
      %{
        level: level["level"],
        small_blind: level["small_blind"],
        big_blind: level["big_blind"],
        ante: level["ante"],
        duration_seconds: level["duration_seconds"]
      }
    end)
    |> Enum.sort_by(& &1.level)
  end

  def levels(_snapshot), do: []

  @doc """
  Перекрашивает стол в финальный.

  Отдельной функцией, а не полем на входе, потому что момент известен
  только по ходу турнира: стол становится финальным тогда, когда все
  остальные закрылись.
  """
  @spec finalize(t(), String.t(), String.t()) :: t()
  def finalize(%__MODULE__{} = setting, felt_color, background_color) do
    %{setting | final?: true, felt_color: felt_color, background_color: background_color}
  end
end
