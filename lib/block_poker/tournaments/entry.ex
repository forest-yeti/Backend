defmodule BlockPoker.Tournaments.Entry do
  @moduledoc """
  Один **вход** в турнир.

  Ключевое слово — вход, а не участник. Повторный вход после вылета — это
  новая запись, а не «докупка» существующей, и из этого следует всё
  остальное:

    * 50 человек с 20 возвратами дают **70 входов**, и сетка выплат
      считает 70 — фонд собран с 70 взносов, и делить его по сетке для 50
      значило бы платить первому месту полуторную долю;
    * `entry_number` различает попытки: по нему история раздач (задача 6)
      отличает первый заход от третьего;
    * в баунти-турнире каждый вход несёт **свою** голову: прежняя уже
      выплачена убийце и не восстанавливается.

  ## Место присваивается только окончательному вылету

  Пока текущий уровень разрешает ребай и лимит игрока не исчерпан, вылет
  — это предложение войти заново с таймером. Место резервируется, но не
  фиксируется: `place` остаётся `nil`. Отказался или истёк таймер — место
  присвоено. Вошёл заново — предыдущие места не сдвигаются, потому что
  у игрока просто нет вылета.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BlockPoker.Tickets.UserTicket
  alias BlockPoker.Tournaments.Tournament

  @type t :: %__MODULE__{}

  @statuses [:registered, :playing, :busted, :paid, :refunded]

  # Статусы, в которых вход занимает место в рассадке. Инвариант «один
  # стек на человека» проверяется относительно ровно этого набора.
  @seated [:registered, :playing]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tournament_entries" do
    belongs_to :tournament, Tournament
    belongs_to :user, BlockPoker.Accounts.User

    field :entry_number, :integer, default: 1
    field :status, Ecto.Enum, values: @statuses, default: :registered

    # Текущая цена головы: стартует с `bounty_part` и растёт при PKO.
    # Публична — без неё PKO не играется: решение о колле зависит от того,
    # сколько стоит соперник.
    field :bounty, :integer, default: 0

    # Сколько с этой головы уже ушло убийцам. Справочно, для инварианта
    # «сумма выплаченных голов плюс головы живых равна собранному».
    field :bounty_paid, :integer, default: 0

    field :addons_count, :integer, default: 0

    # Призовая часть этого входа: сколько он внёс в фонд. У входа по
    # билету считается от номинала билета, а не от цены шаблона.
    field :credited, :integer, default: 0

    field :place, :integer

    # Места, слитые одновременным вылетом с равным стеком: их призы
    # складываются и делятся поровну (`Engine.Elimination`). `nil` —
    # обычный одиночный вылет. Хранится потому, что из `place` группа
    # не выводится, а дорасчёт джобой поднимает результаты из БД.
    field :shared_places, {:array, :integer}

    field :prize, :integer, default: 0

    belongs_to :paid_with_ticket, UserTicket, foreign_key: :paid_with_ticket_id

    field :busted_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc "Занимает ли вход место в рассадке."
  @spec seated?(t()) :: boolean()
  def seated?(%__MODULE__{status: status}), do: status in @seated

  @doc "Оплачен ли вход билетом — в ledger такого входа нет вовсе."
  @spec by_ticket?(t()) :: boolean()
  def by_ticket?(%__MODULE__{paid_with_ticket_id: id}), do: id != nil

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :tournament_id,
      :user_id,
      :entry_number,
      :status,
      :bounty,
      :bounty_paid,
      :addons_count,
      :credited,
      :place,
      :shared_places,
      :prize,
      :paid_with_ticket_id,
      :busted_at
    ])
    |> validate_required([:tournament_id, :user_id, :entry_number, :status])
    |> validate_number(:entry_number, greater_than: 0)
    |> validate_number(:bounty, greater_than_or_equal_to: 0)
    |> validate_number(:bounty_paid, greater_than_or_equal_to: 0)
    |> validate_number(:addons_count, greater_than_or_equal_to: 0)
    |> validate_number(:credited, greater_than_or_equal_to: 0)
    |> validate_number(:prize, greater_than_or_equal_to: 0)
    |> validate_number(:place, greater_than: 0)
    |> assoc_constraint(:tournament)
    |> assoc_constraint(:user)
    # Двойной клик по «войти заново» гасит база, а не проверка в коде:
    # только UNIQUE даёт гарантию при конкурентных ретраях.
    |> unique_constraint([:tournament_id, :user_id, :entry_number])
    |> check_constraint(:entry_number, name: :tournament_entries_values)
  end
end
