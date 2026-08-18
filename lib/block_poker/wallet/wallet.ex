defmodule BlockPoker.Wallet do
  @moduledoc """
  Контекст кошельков.

  Источник истины по деньгам — `wallet_entries` (append-only журнал);
  `user_wallets.amount` — кэш поверх него. Любое движение денег проходит
  через `record_entry/3`, другого пути нет.
  """

  import Ecto.Query

  alias BlockPoker.Repo
  alias BlockPoker.Wallet.{UserWallet, WalletEntry}
  alias Ecto.Multi

  # Стартовые суммы живут здесь и нигде не дублируются (§3 CLAUDE.md).
  @main_default 0
  @play_money_default 10_000

  @spec main_default() :: non_neg_integer()
  def main_default, do: @main_default

  @spec play_money_default() :: non_neg_integer()
  def play_money_default, do: @play_money_default

  @doc """
  Добавляет в `multi` создание кошельков по умолчанию для пользователя,
  лежащего в `multi` под ключом `user_key`.

  `main` создаётся пустым (пустой журнал даёт нулевую сумму — инвариант
  выполняется), стартовые фишки `play_money` записываются обычной операцией
  `deposit` с ключом идемпотентности `"signup:<user_id>"`.
  """
  @spec create_default_wallets(Multi.t(), atom()) :: Multi.t()
  def create_default_wallets(multi, user_key) do
    multi
    |> Multi.insert(:main_wallet, &new_wallet(&1[user_key].id, :main, @main_default))
    |> Multi.insert(:play_money_wallet, &new_wallet(&1[user_key].id, :play_money, 0))
    |> record_entry(:play_money_deposit, fn changes ->
      %{
        wallet_id: changes.play_money_wallet.id,
        amount: @play_money_default,
        type: :deposit,
        idempotency_key: "signup:#{changes[user_key].id}"
      }
    end)
  end

  @spec list_wallets(Ecto.UUID.t()) :: [UserWallet.t()]
  def list_wallets(user_id) do
    UserWallet
    |> where(user_id: ^user_id)
    |> order_by(asc: :type)
    |> Repo.all()
  end

  @spec get_wallet(Ecto.UUID.t(), :main | :play_money) ::
          {:ok, UserWallet.t()} | {:error, :not_found}
  def get_wallet(user_id, type) do
    case Repo.get_by(UserWallet, user_id: user_id, type: type) do
      nil -> {:error, :not_found}
      wallet -> {:ok, wallet}
    end
  end

  @doc """
  Выписка по кошельку, свежие записи первыми.

  Опции: `:limit` (по умолчанию 50), `:offset`.
  """
  @spec list_entries(Ecto.UUID.t(), keyword()) :: [WalletEntry.t()]
  def list_entries(wallet_id, opts \\ []) do
    WalletEntry
    |> where(wallet_id: ^wallet_id)
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(^Keyword.get(opts, :limit, 50))
    |> offset(^Keyword.get(opts, :offset, 0))
    |> Repo.all()
  end

  @doc """
  Бай-ин: фишки уезжают из кошелька на стол.

  Ключ идемпотентности задаёт вызывающий (`"buyin:<reservation_id>"`),
  поэтому ретрай посадки после обрыва не спишет деньги дважды.
  """
  @spec buy_in(Ecto.UUID.t(), :main | :play_money, pos_integer(), String.t(), keyword()) ::
          {:ok, WalletEntry.t()} | {:error, :not_found | :insufficient_funds | Ecto.Changeset.t()}
  def buy_in(user_id, currency, amount, idempotency_key, opts \\ []) when amount > 0 do
    move(user_id, currency, -amount, :buy_in, idempotency_key, opts)
  end

  @doc "Cash-out: стек возвращается в кошелёк. Нулевой стек записи не порождает."
  @spec cash_out(Ecto.UUID.t(), :main | :play_money, non_neg_integer(), String.t(), keyword()) ::
          {:ok, WalletEntry.t() | :noop} | {:error, term()}
  def cash_out(user_id, currency, amount, idempotency_key, opts \\ [])

  def cash_out(_user_id, _currency, 0, _idempotency_key, _opts), do: {:ok, :noop}

  def cash_out(user_id, currency, amount, idempotency_key, opts) when amount > 0 do
    move(user_id, currency, amount, :cash_out, idempotency_key, opts)
  end

  defp move(user_id, currency, amount, type, idempotency_key, opts) do
    with {:ok, wallet} <- get_wallet(user_id, currency) do
      Multi.new()
      |> record_entry(:entry, %{
        wallet_id: wallet.id,
        amount: amount,
        type: type,
        ref_id: opts[:ref_id],
        idempotency_key: idempotency_key,
        meta: opts[:meta]
      })
      |> Repo.transaction()
      |> case do
        {:ok, %{entry: entry}} -> {:ok, entry}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  @doc """
  Добавляет в `multi` шаг записи операции по кошельку.

  Единственный путь изменения денег. Внутри одной транзакции:

    1. блокировка строки кошелька (`SELECT ... FOR UPDATE`);
    2. проверка, что итоговый баланс `>= 0`;
    3. `INSERT` в `wallet_entries` (UNIQUE на `idempotency_key`);
    4. `UPDATE user_wallets.amount`.

  `FOR UPDATE` нужен потому, что «прочитать баланс → проверить → записать»
  без блокировки допускает гонку двух параллельных списаний, каждое из которых
  по отдельности проходит проверку.

  Нарушение UNIQUE по `idempotency_key` — не ошибка, а сигнал «операция уже
  выполнена»: возвращается существующая запись и баланс не меняется, иначе
  ретрай клиента превратится в видимую ошибку при успешной операции.

  `attrs` — карта или функция от накопленных `changes`.
  """
  @spec record_entry(Multi.t(), atom(), map() | (map() -> map())) :: Multi.t()
  def record_entry(multi, name, attrs) do
    Multi.run(multi, name, fn repo, changes ->
      attrs = if is_function(attrs, 1), do: attrs.(changes), else: attrs
      do_record_entry(repo, attrs)
    end)
  end

  defp do_record_entry(repo, attrs) do
    attrs = Map.new(attrs)

    with {:ok, wallet} <- lock_wallet(repo, attrs.wallet_id),
         balance_after = wallet.amount + attrs.amount,
         :ok <- ensure_non_negative(balance_after) do
      insert_entry(repo, wallet, attrs, balance_after)
    end
  end

  defp lock_wallet(repo, wallet_id) do
    query = from w in UserWallet, where: w.id == ^wallet_id, lock: "FOR UPDATE"

    case repo.one(query) do
      nil -> {:error, :not_found}
      wallet -> {:ok, wallet}
    end
  end

  defp ensure_non_negative(balance_after) when balance_after >= 0, do: :ok
  defp ensure_non_negative(_balance_after), do: {:error, :insufficient_funds}

  defp insert_entry(repo, wallet, attrs, balance_after) do
    changeset =
      WalletEntry.changeset(%WalletEntry{}, Map.put(attrs, :balance_after, balance_after))

    case repo.insert(changeset) do
      {:ok, entry} ->
        with {:ok, _wallet} <- repo.update(UserWallet.balance_changeset(wallet, balance_after)) do
          {:ok, entry}
        end

      {:error, changeset} ->
        # Дубль ловит именно БД, а не предварительный SELECT: только UNIQUE
        # даёт гарантию при конкурентных ретраях.
        if duplicate_key?(changeset),
          do: {:ok, repo.get_by!(WalletEntry, idempotency_key: attrs.idempotency_key)},
          else: {:error, changeset}
    end
  end

  defp new_wallet(user_id, type, amount) do
    UserWallet.changeset(%UserWallet{}, %{user_id: user_id, type: type, amount: amount})
  end

  defp duplicate_key?(changeset) do
    Enum.any?(changeset.errors, fn
      {:idempotency_key, {_msg, opts}} -> opts[:constraint] == :unique
      _other -> false
    end)
  end
end
