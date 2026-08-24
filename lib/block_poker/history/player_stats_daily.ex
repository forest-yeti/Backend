defmodule BlockPoker.History.PlayerStatsDaily do
  @moduledoc """
  Дневной агрегат показателей игрока: единственное, что переживает чистку
  раздач.

  Считается инкрементально по концу каждой раздачи
  (`INSERT ... ON DUPLICATE KEY UPDATE col = col + VALUES(col)`), а не
  свёрткой перед удалением. Причина принципиальная: агрегат, посчитанный
  на лету, невозможно потерять при сбое джоба чистки и невозможно
  рассинхронизировать с уже удалёнными данными.

  **Единица `net` зависит от режима.** В строках `cash` и `ofc_cash` это
  деньги в минимальных единицах, в `sit_and_go` и `mtt` — турнирные фишки,
  которые складывать с деньгами нельзя: разные турниры имеют разный
  номинал стартового стека. Именно поэтому `game_mode` входит в первичный
  ключ — запрос никогда не суммирует строки разных режимов. Денежный итог
  турнира здесь не живёт вовсе: ROI и ITM считаются из
  `History.TournamentResult`.

  OFC-счётчики в строках других режимов нулевые, и наоборот: `vpip`,
  `pfr`, `bb_sum` в строке `ofc_cash` всегда ноль — понятий добровольного
  вложения и большого блайнда там нет.

  `bb_sum` — сумма больших блайндов по раздачам, а не среднее: проценты и
  средние не складываются, а агрегат обязан суммироваться по любому
  набору дней. Winrate = `net / bb_sum * 100`.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  # Разрез по лимиту участвует в первичном ключе, а `NULL` в MySQL не
  # сравним сам с собой — поэтому «разреза нет» хранится нулевым UUID.
  @no_setting "00000000-0000-0000-0000-000000000000"

  @counters [
    :hands,
    :vpip,
    :pfr,
    :three_bet_chances,
    :three_bets,
    :saw_flop,
    :showdowns,
    :aggressive,
    :calls,
    :net,
    :invested,
    :won,
    :rake_paid,
    :ev_net,
    :bb_sum,
    :ofc_points,
    :fantasy_entries,
    :fantasy_holds,
    :fantasy_hands,
    :fouls,
    :scoops,
    :royalty_top,
    :royalty_middle,
    :royalty_bottom
  ]

  @primary_key false
  @foreign_key_type :binary_id
  schema "player_stats_daily" do
    field :user_id, :binary_id, primary_key: true
    field :day, :date, primary_key: true
    field :game_mode, Ecto.Enum, values: [:cash, :sit_and_go, :mtt, :ofc_cash], primary_key: true
    field :setting_id, :binary_id, primary_key: true

    for counter <- @counters do
      field counter, :integer, default: 0
    end

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Счётчики, которые складываются при инкременте."
  @spec counters() :: [atom()]
  def counters, do: @counters

  @doc "Значение `setting_id` для строки без разреза по лимиту."
  @spec no_setting() :: String.t()
  def no_setting, do: @no_setting
end
