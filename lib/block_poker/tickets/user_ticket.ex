defmodule BlockPoker.Tickets.UserTicket do
  @moduledoc """
  Экземпляр билета в руках игрока.

  **Строка на экземпляр, а не количество в колонке.** У одного игрока
  может быть несколько одинаковых билетов, и счётчик `count` потребовал
  бы атомарного декремента под конкурентной регистрацией, а история
  «откуда пришёл и куда ушёл» пропала бы вовсе. Строка со статусом даёт
  и то, и другое: погашение — это `UPDATE ... WHERE status = 'active'`
  с проверкой числа затронутых строк, то есть та же защита, что у ledger.

  ## Статусы

    * `active` — можно предъявить на регистрации;
    * `used` — погашен в конкретный турнир (`used_in_tournament_id`);
    * `expired` — вышел срок; гасит Oban-джоба;
    * `revoked` — отозван оператором.

  Возврат при отмене турнира — это `used → active` **в той же
  транзакции**, что и денежные возвраты остальным: иначе есть окно,
  в котором игрок уже не в турнире и ещё без билета.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BlockPoker.Tickets.Ticket

  @type t :: %__MODULE__{}

  @statuses [:active, :used, :expired, :revoked]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "user_tickets" do
    belongs_to :ticket, Ticket
    belongs_to :user, BlockPoker.Accounts.User

    field :status, Ecto.Enum, values: @statuses, default: :active

    # Откуда взялся: `tournament:<id>` / `admin` / `promo`. Строка, а не
    # ссылка: источником может быть и то, чего нет в БД таблицей.
    field :issued_by, :string, default: "admin"

    belongs_to :used_in_tournament, BlockPoker.Tournaments.Tournament,
      foreign_key: :used_in_tournament_id

    field :expires_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(user_ticket, attrs) do
    user_ticket
    |> cast(attrs, [:ticket_id, :user_id, :status, :issued_by, :expires_at])
    |> validate_required([:ticket_id, :user_id, :issued_by])
    |> validate_length(:issued_by, max: 64)
    |> assoc_constraint(:ticket)
    |> assoc_constraint(:user)
    |> unique_constraint([:used_in_tournament_id, :user_id],
      name: :user_tickets_one_per_tournament
    )
  end

  @doc "Погашение: билет уходит в турнир и больше никуда не пустит."
  @spec redeem_changeset(t(), Ecto.UUID.t()) :: Ecto.Changeset.t()
  def redeem_changeset(%__MODULE__{} = user_ticket, tournament_id) do
    user_ticket
    |> change(status: :used, used_in_tournament_id: tournament_id)
    |> unique_constraint([:used_in_tournament_id, :user_id],
      name: :user_tickets_one_per_tournament
    )
  end

  @doc """
  Возврат: билет снова активен и снова ничей.

  `used_in_tournament_id` обнуляется вместе со статусом — иначе
  уникальный индекс «один билет на турнир» не пустил бы игрока
  в следующий запуск того же шаблона.
  """
  @spec refund_changeset(t()) :: Ecto.Changeset.t()
  def refund_changeset(%__MODULE__{} = user_ticket) do
    change(user_ticket, status: :active, used_in_tournament_id: nil)
  end

  @doc "Годен ли билет к предъявлению на момент `now`."
  @spec valid?(t(), DateTime.t()) :: boolean()
  def valid?(%__MODULE__{status: :active, expires_at: nil}, _now), do: true

  def valid?(%__MODULE__{status: :active, expires_at: expires_at}, now) do
    DateTime.compare(expires_at, now) == :gt
  end

  def valid?(%__MODULE__{}, _now), do: false
end
