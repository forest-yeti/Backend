defmodule BlockPoker.Wallet.UserWallet do
  @moduledoc """
  Кошелёк игрока: денормализованный кэш текущего баланса поверх ledger'а
  (`BlockPoker.Wallet.WalletEntry`), который и является источником истины.

  Инвариант: `amount == SUM(wallet_entries.amount) WHERE wallet_id = id`.
  Поле `amount` меняется **только** через контекст `BlockPoker.Wallet`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BlockPoker.Accounts.User

  @type t :: %__MODULE__{}

  @types [:main, :play_money]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "user_wallets" do
    field :type, Ecto.Enum, values: @types
    field :amount, :integer, default: 0

    # Касса рума. Её баланс — накопленный результат: комиссии и рейк его
    # поднимают, оверлей опускает, и в начале жизни рума он законно
    # отрицателен. Запрет минуса существует ради игроков, и к кассе
    # неприменим — поэтому флаг на кошельке, а не общее послабление.
    field :system, :boolean, default: false

    belongs_to :user, User

    timestamps(type: :utc_datetime_usec)
  end

  @spec types() :: [:main | :play_money]
  def types, do: @types

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(wallet, attrs) do
    wallet
    |> cast(attrs, [:user_id, :type, :amount, :system])
    |> validate_required([:user_id, :type, :amount])
    |> validate_number(:amount, greater_than_or_equal_to: 0)
    |> assoc_constraint(:user)
    |> unique_constraint([:user_id, :type])
    |> check_constraint(:amount, name: :user_wallets_amount_non_negative)
  end

  @doc "Может ли кошелёк уйти в минус. Может только касса рума."
  @spec allows_negative?(t()) :: boolean()
  def allows_negative?(%__MODULE__{system: system}), do: system

  @doc "Изменение баланса. Единственный вызывающий — `BlockPoker.Wallet`."
  @spec balance_changeset(t(), integer()) :: Ecto.Changeset.t()
  def balance_changeset(wallet, new_amount) do
    wallet
    |> change(amount: new_amount)
    |> then(fn changeset ->
      if allows_negative?(wallet),
        do: changeset,
        else: validate_number(changeset, :amount, greater_than_or_equal_to: 0)
    end)
    |> check_constraint(:amount, name: :user_wallets_amount_non_negative)
  end
end
