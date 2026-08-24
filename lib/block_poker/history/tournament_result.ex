defmodule BlockPoker.History.TournamentResult do
  @moduledoc """
  Итог турнира для одного **входа** игрока.

  Строка на вход, а не на игрока: три ре-энтри дают три строки со своим
  взносом, своим временем вылета и своим местом. Это единственная форма,
  из которой обе величины считаются корректно — ROI суммирует взносы всех
  входов, а средняя финишная позиция берётся по последнему входу
  (`max(entry_index)`), иначе ранние вылеты игрока, дошедшего затем до
  финального стола, испортили бы его среднюю позицию.

  Строку получают все, а не только вылетевшие: победитель (`won`),
  дожившие до отмены (`cancelled`) и разрегистрировавшиеся до старта
  (`unregistered`). Без последних двух ROI врёт — взнос был, а расхода в
  статистике нет.

  `bounty_final` в ROI **не входит**: собственная невыплаченная голова —
  это не полученные деньги. Поле хранится справочно, для разбора
  конкретного турнира.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @formats [:sit_and_go, :mtt]
  @outcomes [:busted, :won, :cancelled, :unregistered]
  @kinds [:initial, :reentry]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tournament_results" do
    # Идемпотентность записи держится на этом поле: перезапуск
    # `TournamentServer`, повтор Oban-задачи и дозапись при завершении
    # турнира не создают вторых строк.
    field :entry_id, :binary_id
    field :tournament_id, :binary_id

    belongs_to :user, BlockPoker.Accounts.User

    field :title, :string
    field :tournament_setting_id, :binary_id
    field :format, Ecto.Enum, values: @formats
    # Масштаб взносов и призов этого входа.
    field :currency, Ecto.Enum, values: [:main, :play_money], default: :main
    field :bounty, :boolean, default: false

    field :entry_kind, Ecto.Enum, values: @kinds, default: :initial
    field :entry_index, :integer, default: 0

    field :buy_in, :integer, default: 0
    field :entry_fee, :integer, default: 0
    field :addons_count, :integer, default: 0
    field :addons_cost, :integer, default: 0

    field :prize, :integer, default: 0
    field :bounty_paid, :integer, default: 0
    field :bounty_final, :integer, default: 0
    field :refund, :integer, default: 0

    field :place, :integer

    # Без числа входов «5-е место» не значит ничего: пятое из девяти и
    # пятое из девяноста — разные достижения.
    field :entrants, :integer
    field :itm, :boolean, default: false
    field :outcome, Ecto.Enum, values: @outcomes

    field :hands_played, :integer, default: 0

    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @spec formats() :: [atom()]
  def formats, do: @formats

  @spec outcomes() :: [atom()]
  def outcomes, do: @outcomes

  @doc "Полная цена входа: взнос, комиссия и аддоны."
  @spec cost(t()) :: non_neg_integer()
  def cost(%__MODULE__{} = result), do: result.buy_in + result.entry_fee + result.addons_cost

  @doc "Что вход вернул: приз, полученные головы и возврат."
  @spec income(t()) :: non_neg_integer()
  def income(%__MODULE__{} = result), do: result.prize + result.bounty_paid + result.refund

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(result, attrs) do
    result
    |> cast(attrs, [
      :entry_id,
      :tournament_id,
      :user_id,
      :title,
      :tournament_setting_id,
      :format,
      :currency,
      :bounty,
      :entry_kind,
      :entry_index,
      :buy_in,
      :entry_fee,
      :addons_count,
      :addons_cost,
      :prize,
      :bounty_paid,
      :bounty_final,
      :refund,
      :place,
      :entrants,
      :itm,
      :outcome,
      :hands_played,
      :started_at,
      :finished_at
    ])
    |> validate_required([:entry_id, :tournament_id, :user_id, :format, :outcome])
    |> unique_constraint(:entry_id)
  end
end
