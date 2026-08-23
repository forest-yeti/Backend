defmodule BlockPoker.Tournaments.SeatSnapshot do
  @moduledoc """
  Снимок рассадки и стеков турнира — единственное, что не выводится из
  остальных таблиц.

  Участники, места, фонд, уровень и `starts_at` персистентны сами по себе;
  кто за каким столом сидит и сколько у него фишек — нет. Поэтому
  `TournamentServer` пишет снимок **на каждом завершении раздачи**,
  асинхронно, как историю раздач: падение процесса турнира — самое дорогое
  падение в системе, и без снимка оно означало бы потерю игры.

  Снимок один на турнир и переписывается: прошлые состояния хранит
  `hand_actions`, а восстанавливаться нужно из последнего.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BlockPoker.Tournaments.Tournament

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tournament_seat_snapshots" do
    belongs_to :tournament, Tournament

    field :level, :integer
    field :hands_played, :integer, default: 0

    # Список карт `%{"table" => n, "seat" => n, "entry_id" => ..., "stack" => n}`.
    # JSON, а не таблица: снимок читается целиком и никогда по частям,
    # а таблица потребовала бы удалять и вставлять десятки строк на
    # каждой раздаче.
    field :seats, {:array, :map}

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:tournament_id, :level, :hands_played, :seats])
    |> validate_required([:tournament_id, :level, :seats])
    |> validate_number(:level, greater_than: 0)
    |> validate_number(:hands_played, greater_than_or_equal_to: 0)
    |> assoc_constraint(:tournament)
    |> unique_constraint(:tournament_id)
  end
end
