defmodule BlockPoker.Tournaments.Schedule do
  @moduledoc """
  Сетка запусков шаблона: «каждый день в 21:30», «по субботам», «один раз
  первого сентября».

  `start_time` — **местное время рума** (пояс в конфиге, см.
  `Engine.RoomTime`). В UTC оно переводится на конкретную дату, потому
  что «21:30» — обещание игроку, а не момент времени: при переходе на
  летнее время турнир обязан остаться в 21:30 по часам игрока.

  Три формы записи, и больше никаких:

    * `repeat: true, weekday: nil` — каждый день;
    * `repeat: true, weekday: 6` — каждую субботу;
    * `repeat: false, run_on: ~D[2026-09-01]` — один раз, в эту дату.

  У разового запуска `weekday` обязан быть пустым: дата уже сказала всё,
  а второй источник правды о том же дне создал бы расписание, которое
  молча не срабатывает.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BlockPoker.Engine.RoomTime

  @type t :: %__MODULE__{}

  @editable [:start_time, :weekday, :repeat, :run_on, :enabled]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tournament_schedules" do
    belongs_to :setting, BlockPoker.Tournaments.TournamentSetting,
      foreign_key: :tournament_setting_id

    field :start_time, :time
    field :weekday, :integer
    field :repeat, :boolean, default: true
    field :run_on, :date
    field :enabled, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, @editable)
    |> validate_required([:start_time])
    |> validate_inclusion(:weekday, 1..7)
    |> validate_recurrence()
    |> truncate_seconds()
    |> check_constraint(:repeat, name: :tournament_schedules_recurrence)
  end

  defp validate_recurrence(changeset) do
    case get_field(changeset, :repeat) do
      true ->
        if get_field(changeset, :run_on),
          do: add_error(changeset, :run_on, "дата задана у повторяющегося расписания"),
          else: changeset

      false ->
        changeset
        |> validate_required([:run_on])
        |> then(fn cs ->
          if get_field(cs, :weekday),
            do: add_error(cs, :weekday, "день недели задан у разового запуска"),
            else: cs
        end)

      nil ->
        changeset
    end
  end

  # Секунды в расписании рума не значат ничего: турнир начинается в 21:30,
  # а не в 21:30:07. Обрезаем на записи, чтобы идемпотентность инстансов
  # не зависела от того, как оператор набрал время.
  defp truncate_seconds(changeset) do
    case get_change(changeset, :start_time) do
      nil -> changeset
      time -> put_change(changeset, :start_time, %{time | second: 0, microsecond: {0, 0}})
    end
  end

  @doc """
  Моменты запуска в окне `[from, to]` (UTC).

  Выключенное расписание не даёт ничего: проверка здесь, а не у
  вызывающего, потому что «выключено» — это свойство расписания.
  """
  @spec occurrences(t(), DateTime.t(), DateTime.t()) :: [DateTime.t()]
  def occurrences(%__MODULE__{enabled: false}, _from, _to), do: []

  def occurrences(%__MODULE__{} = schedule, from, to) do
    RoomTime.occurrences(
      %{
        start_time: schedule.start_time,
        weekday: schedule.weekday,
        repeat: schedule.repeat,
        run_on: schedule.run_on
      },
      from,
      to
    )
  end
end
