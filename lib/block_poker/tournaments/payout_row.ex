defmodule BlockPoker.Tournaments.PayoutRow do
  @moduledoc """
  Строка сетки выплат: доля фонда либо билет за интервал мест при
  интервале явки.

  Почему сетка, а не фиксированный массив долей, и как из неё считаются
  суммы — в `Engine.TournamentPayout`. Схема только хранит строку;
  арифметика и проверка набора целиком живут в ядре, потому что они
  свойства **таблицы**, а не строки.

  Ровно одно из `share_ppm` / `ticket_id` заполнено, и стережёт это
  constraint БД: строка с обоими не имеет смысла (непонятно, что выдано),
  строка без обоих — место без приза.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BlockPoker.Engine.TournamentPayout
  alias BlockPoker.Tickets.Ticket

  @type t :: %__MODULE__{}

  @editable [:entries_from, :entries_to, :place_from, :place_to, :share_ppm, :ticket_id]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tournament_payouts" do
    belongs_to :setting, BlockPoker.Tournaments.TournamentSetting,
      foreign_key: :tournament_setting_id

    # `entries_to: nil` — «и выше»: последняя полоса обязана быть открытой,
    # иначе существует явка, для которой турнир нечем закончить.
    field :entries_from, :integer
    field :entries_to, :integer

    field :place_from, :integer
    field :place_to, :integer

    field :share_ppm, :integer

    belongs_to :ticket, Ticket

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(row, attrs) do
    row
    |> cast(attrs, @editable)
    |> validate_required([:entries_from, :place_from, :place_to])
    |> validate_number(:entries_from, greater_than_or_equal_to: 2)
    |> validate_number(:place_from, greater_than_or_equal_to: 1)
    |> validate_number(:share_ppm, greater_than: 0, less_than_or_equal_to: TournamentPayout.ppm())
    |> validate_ranges()
    |> validate_prize()
    |> assoc_constraint(:ticket)
    |> check_constraint(:entries_from, name: :tournament_payouts_ranges)
    |> check_constraint(:share_ppm, name: :tournament_payouts_prize)
  end

  defp validate_ranges(changeset) do
    from = get_field(changeset, :entries_from)
    to = get_field(changeset, :entries_to)
    place_from = get_field(changeset, :place_from)
    place_to = get_field(changeset, :place_to)

    changeset
    |> then(fn cs ->
      if is_integer(to) and is_integer(from) and to < from,
        do: add_error(cs, :entries_to, "верхняя граница явки ниже нижней"),
        else: cs
    end)
    |> then(fn cs ->
      if is_integer(place_to) and is_integer(place_from) and place_to < place_from,
        do: add_error(cs, :place_to, "верхняя граница мест ниже нижней"),
        else: cs
    end)
    |> then(fn cs ->
      # Нельзя оплачивать больше мест, чем гарантированно будет входов
      # в этой полосе: сетка на шесть мест при пяти входах неисполнима.
      if is_integer(place_to) and is_integer(from) and place_to > from,
        do: add_error(cs, :place_to, "мест больше, чем входов в этой полосе"),
        else: cs
    end)
  end

  defp validate_prize(changeset) do
    share = get_field(changeset, :share_ppm)
    ticket = get_field(changeset, :ticket_id)

    case {share, ticket} do
      {nil, nil} ->
        add_error(changeset, :share_ppm, "место без приза")

      {share, ticket} when not is_nil(share) and not is_nil(ticket) ->
        add_error(changeset, :share_ppm, "приз либо деньгами, либо билетом")

      _one ->
        changeset
    end
  end

  @doc """
  Строка в виде, который читает `Engine.TournamentPayout`.

  Номинал билета берётся из связанного `Ticket`, а не из шаблона, на
  который тот пускает: цена турнира может вырасти, а выданный билет
  обязан считаться по своей.
  """
  @spec to_row(t()) :: TournamentPayout.row()
  def to_row(%__MODULE__{} = row) do
    %{
      entries_from: row.entries_from,
      entries_to: row.entries_to,
      place_from: row.place_from,
      place_to: row.place_to,
      share_ppm: row.share_ppm,
      ticket_id: row.ticket_id,
      ticket_value: ticket_value(row)
    }
  end

  defp ticket_value(%__MODULE__{ticket: %Ticket{face_value: value}}), do: value
  defp ticket_value(%__MODULE__{}), do: nil
end
