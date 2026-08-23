defmodule BlockPoker.Tournaments.Tournament do
  @moduledoc """
  Инстанс турнира: конкретный запуск конкретного шаблона в конкретное
  время. Это то, во что игрок регистрируется.

  Живёт и в БД, и в процессе (`TournamentServer`). В БД — всё, что
  обязано пережить рестарт: участники, места, фонд, уровень и `starts_at`.
  В процессе — рассадка и стеки, и они снапшотятся отдельной таблицей на
  каждом завершении раздачи.

  ## Снапшот настроек обязателен

  Инстанс копирует себе уровни, сетку выплат и цены в момент перехода
  в `registering` и дальше **не читает шаблон вовсе**. Причина та же, по
  которой это делает Sit & Go: правка структуры в БД не должна поднимать
  блайнды посреди идущего турнира. Здесь она сильнее — турнир идёт часами,
  и вероятность правки во время игры реальна.

  ## Статусы

      announced → registering → running → late_reg_closed → finishing → finished
                       │
                       └────────→ cancelled

    * `announced` — виден в лобби с отсчётом, регистрация закрыта;
    * `registering` — принимает регистрации, ещё не идёт;
    * `running` — раздачи идут, поздняя регистрация открыта;
    * `late_reg_closed` — вход и ребаи закрыты; **здесь фиксируется фонд**;
    * `finishing` — остался один стол (финалка), считаются места;
    * `finished` — все места распределены, выплаты записаны;
    * `cancelled` — минимум не набран, возвраты сделаны, участников нет.

  Отменить можно только турнир, который ещё не начался: остановить идущий
  нельзя, можно лишь отключить будущие запуски шаблона.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BlockPoker.Tournaments.{Entry, Schedule, TournamentSetting}

  @type t :: %__MODULE__{}

  @statuses [
    :announced,
    :registering,
    :running,
    :late_reg_closed,
    :finishing,
    :finished,
    :cancelled
  ]

  # Статусы, в которых турнир ещё не раздал ни одной карты. Ровно они
  # отделяют «можно отменить и разрегистрироваться» от «поздно».
  @pre_game [:announced, :registering]

  # Статусы, в которых турнир идёт. Дальше только конец.
  @live [:running, :late_reg_closed, :finishing]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tournaments" do
    belongs_to :setting, TournamentSetting, foreign_key: :tournament_setting_id
    belongs_to :schedule, Schedule, foreign_key: :schedule_id

    field :starts_at, :utc_datetime_usec
    field :status, Ecto.Enum, values: @statuses, default: :announced

    field :late_reg_until, :utc_datetime_usec

    # Входы и люди — разные числа. По входам считается фонд и сетка
    # выплат, по людям — порог старта и потолок одновременно играющих.
    field :entries_count, :integer, default: 0
    field :players_count, :integer, default: 0
    field :reentries_count, :integer, default: 0
    field :addons_count, :integer, default: 0

    field :prize_pool, :integer, default: 0
    field :overlay, :integer, default: 0
    field :bounty_pool, :integer, default: 0

    field :snapshot, :map

    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    has_many :entries, Entry, foreign_key: :tournament_id

    timestamps(type: :utc_datetime_usec)
  end

  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc "Турнир ещё не начался: можно отменить и разрегистрироваться."
  @spec pre_game?(t()) :: boolean()
  def pre_game?(%__MODULE__{status: status}), do: status in @pre_game

  @doc "Турнир идёт."
  @spec live?(t()) :: boolean()
  def live?(%__MODULE__{status: status}), do: status in @live

  @doc """
  Принимает ли турнир вход прямо сейчас — первичный или повторный.

  Одно правило на оба случая (§2.3): пока уровень разрешает ребай, можно
  и войти впервые, и вернуться выбывшим. До старта вход открыт по статусу,
  после — по флагу текущего уровня, который знает процесс.
  """
  @spec registering?(t()) :: boolean()
  def registering?(%__MODULE__{status: :registering}), do: true
  def registering?(%__MODULE__{status: :running}), do: true
  def registering?(%__MODULE__{}), do: false

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(tournament, attrs) do
    tournament
    |> cast(attrs, [
      :tournament_setting_id,
      :schedule_id,
      :starts_at,
      :status,
      :late_reg_until,
      :entries_count,
      :players_count,
      :reentries_count,
      :addons_count,
      :prize_pool,
      :overlay,
      :bounty_pool,
      :snapshot,
      :started_at,
      :finished_at
    ])
    |> validate_required([:tournament_setting_id, :starts_at, :status])
    |> validate_counters()
    |> assoc_constraint(:setting)
    |> assoc_constraint(:schedule)
    |> unique_constraint([:schedule_id, :starts_at])
    |> check_constraint(:entries_count, name: :tournaments_counters)
  end

  defp validate_counters(changeset) do
    Enum.reduce(
      [
        :entries_count,
        :players_count,
        :reentries_count,
        :addons_count,
        :prize_pool,
        :overlay,
        :bounty_pool
      ],
      changeset,
      &validate_number(&2, &1, greater_than_or_equal_to: 0)
    )
  end

  @doc """
  Момент, с которого инстанс появляется в лобби и начинает принимать
  регистрации.
  """
  @spec registration_opens_at(t(), TournamentSetting.t()) :: DateTime.t()
  def registration_opens_at(%__MODULE__{starts_at: starts_at}, %TournamentSetting{} = setting) do
    DateTime.add(starts_at, -setting.registration_opens_before, :second)
  end

  @doc """
  Крайний срок, до которого ждём набора минимума.

  Турнир, не набравший людей к `starts_at`, ждёт ещё
  `cancel_refund_grace_seconds` и только потом отменяется: «ровно в
  секунду старта» — не то время, когда стоит рубить вечер.
  """
  @spec cancel_deadline(t(), TournamentSetting.t()) :: DateTime.t()
  def cancel_deadline(%__MODULE__{starts_at: starts_at}, %TournamentSetting{} = setting) do
    DateTime.add(starts_at, setting.cancel_refund_grace_seconds, :second)
  end
end
