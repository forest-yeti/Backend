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
  alias Phoenix.PubSub

  @pubsub BlockPoker.PubSub

  # Стартовые суммы живут здесь и нигде не дублируются (§3 CLAUDE.md).
  # Касса рума. Заводится миграцией `CreateHouseWallet` с этим же
  # идентификатором: касса одна, и искать её по признаку незачем.
  @house_user_id "00000000-0000-0000-0000-0000000000ff"

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

  @doc """
  Топик, на котором игрок слышит движение своих денег.

  Не `"wallet:<id>"`: на топик с именем канала Phoenix подписывает канал
  сам, и вторая явная подписка доставляла бы каждое событие дважды.
  """
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(user_id), do: "wallet_events:#{user_id}"

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
  Касса рума: кошелёк, с которого идёт оверлей и на который падают
  комиссии.

  Идентификатор фиксирован (заводится миграцией `CreateHouseWallet`), а не
  ищется по признаку: касса одна на рум, и код обращается к ней по имени.
  Её отсутствие — не игровая ситуация, а сломанная установка, поэтому
  ошибка, а не пустой результат.
  """
  @spec house_wallet(:main | :play_money) :: {:ok, UserWallet.t()} | {:error, :not_found}
  def house_wallet(currency), do: get_wallet(house_user_id(), currency)

  @doc "Идентификатор кассы рума."
  @spec house_user_id() :: Ecto.UUID.t()
  def house_user_id, do: @house_user_id

  @doc """
  Выписка по кошельку, свежие записи первыми.

  Порядок задаёт `seq` — счётчик самой БД. По времени вставки журнал
  сортировать нельзя: операции, попавшие в одну микросекунду, шли бы
  в произвольном порядке.

  Опции: `:limit` (по умолчанию 50), `:offset`.
  """
  @spec list_entries(Ecto.UUID.t(), keyword()) :: [WalletEntry.t()]
  def list_entries(wallet_id, opts \\ []) do
    WalletEntry
    |> where(wallet_id: ^wallet_id)
    |> order_by(desc: :seq)
    |> limit(^Keyword.get(opts, :limit, 50))
    |> offset(^Keyword.get(opts, :offset, 0))
    |> Repo.all()
  end

  @doc """
  Запись по ключу идемпотентности либо `nil`.

  Нужна тем, кто обязан отличить «операция ещё не выполнялась» от «уже
  выполнена»: сам `record_entry/3` при повторе молча возвращает старую
  запись, и по её виду повтор неотличим от первого раза. Панели
  администратора это различие важно — второй записи в журнал действий по
  тому же ключу быть не должно.
  """
  @spec get_entry_by_key(String.t()) :: WalletEntry.t() | nil
  def get_entry_by_key(idempotency_key) do
    Repo.get_by(WalletEntry, idempotency_key: idempotency_key)
  end

  @doc """
  Выписка по всем кошелькам игрока сразу, свежие записи первыми.

  Курсор — `seq`, счётчик самой БД: по времени вставки журнал сортировать
  нельзя, операции в одной микросекунде встали бы в произвольном порядке.
  """
  @spec list_user_entries(Ecto.UUID.t(), keyword()) :: [map()]
  def list_user_entries(user_id, opts \\ []) do
    from(e in WalletEntry,
      join: w in UserWallet,
      on: w.id == e.wallet_id,
      where: w.user_id == ^user_id,
      select: %{
        id: e.id,
        seq: e.seq,
        currency: w.type,
        amount: e.amount,
        type: e.type,
        balance_after: e.balance_after,
        ref_id: e.ref_id,
        at: e.inserted_at
      }
    )
    |> then(fn query ->
      case Keyword.get(opts, :currency) do
        nil -> query
        currency -> where(query, [_e, w], w.type == ^currency)
      end
    end)
    |> then(fn query ->
      case Keyword.get(opts, :before_seq) do
        seq when is_integer(seq) -> where(query, [e], e.seq < ^seq)
        _other -> query
      end
    end)
    |> order_by([e], desc: e.seq)
    |> limit(^Keyword.get(opts, :limit, 50))
    |> Repo.all()
  end

  @doc """
  Сумма журнала по каждому из кошельков: `%{wallet_id => сумма}`.

  Источник истины по деньгам — журнал, а `user_wallets.amount` лишь кэш
  поверх него. Эта функция и есть та самая сверка, которую §11 CLAUDE.md
  требует уметь делать.
  """
  @spec ledger_sums([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => integer()}
  def ledger_sums([]), do: %{}

  def ledger_sums(wallet_ids) do
    WalletEntry
    |> where([e], e.wallet_id in ^wallet_ids)
    |> group_by([e], e.wallet_id)
    |> select([e], {e.wallet_id, sum(e.amount)})
    |> Repo.all()
    |> Map.new(fn {wallet_id, sum} -> {wallet_id, to_integer(sum)} end)
  end

  defp to_integer(nil), do: 0
  defp to_integer(%Decimal{} = sum), do: Decimal.to_integer(sum)
  defp to_integer(sum), do: sum

  @doc """
  Сумма записей одного типа с одной меткой (`ref_id`) — «сколько уже
  получено по этой причине», не читая всю выписку. Например: сколько
  баунти игрок заработал в конкретном турнире (`ref_id` — id турнира,
  тип — `:tournament_bounty`).

  `0`, если записей нет — это не ошибка, а «пока ничего».
  """
  @spec sum_by_ref(Ecto.UUID.t(), atom(), String.t()) :: integer()
  def sum_by_ref(wallet_id, type, ref_id) do
    # MySQL отдаёт SUM() десятичным числом даже по целочисленной колонке —
    # деньги в `amount` всегда целые, `Decimal` наружу отдавать незачем.
    case WalletEntry
         |> where(wallet_id: ^wallet_id, type: ^type, ref_id: ^ref_id)
         |> Repo.aggregate(:sum, :amount) do
      nil -> 0
      %Decimal{} = sum -> Decimal.to_integer(sum)
      sum -> sum
    end
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

  @doc """
  Выплата приза за место в турнире.

  Отдельно от `cash_out/5` намеренно: cash-out возвращает игроку фишки,
  которые он сам принёс на стол, а приз приходит из призового фонда и с
  его стеком не связан. Нулевая выплата записи не порождает — место вне
  призовой зоны это не операция.
  """
  @spec award_prize(Ecto.UUID.t(), :main | :play_money, non_neg_integer(), String.t(), keyword()) ::
          {:ok, WalletEntry.t() | :noop} | {:error, term()}
  def award_prize(user_id, currency, amount, idempotency_key, opts \\ [])

  def award_prize(_user_id, _currency, 0, _idempotency_key, _opts), do: {:ok, :noop}

  def award_prize(user_id, currency, amount, idempotency_key, opts) when amount > 0 do
    move(user_id, currency, amount, :prize, idempotency_key, opts)
  end

  @doc """
  Произвольная запись журнала — тот же `move/6`, но тип называет
  вызывающий.

  Существует ради турниров: там типов операций восемь, и заводить по
  паре функций на каждый значило бы восемь раз переписать одно и то же.
  Ноль записи не порождает: операция на нулевую сумму — не операция.

  Для **атомарных** сценариев (взнос и комиссия одной транзакцией,
  возврат всем участникам сразу) эта функция не годится — там нужен
  общий `Ecto.Multi`, и собирается он из `record_entry/3`.
  """
  @spec record(
          Ecto.UUID.t(),
          :main | :play_money,
          integer(),
          atom(),
          String.t(),
          keyword()
        ) :: {:ok, WalletEntry.t() | :noop} | {:error, term()}
  def record(user_id, currency, amount, type, idempotency_key, opts \\ [])

  def record(_user_id, _currency, 0, _type, _idempotency_key, _opts), do: {:ok, :noop}

  def record(user_id, currency, amount, type, idempotency_key, opts) do
    move(user_id, currency, amount, type, idempotency_key, opts)
  end

  @doc """
  Рассылает событие о записи журнала.

  Нужна тем, кто собрал свой `Ecto.Multi` из `record_entry/3`: событие
  обязано уйти **после коммита**, а внутри `Multi` этого момента ещё нет.
  Подписчик, разбуженный на неподтверждённой записи, прочитал бы старый
  баланс и запомнил его как текущий.

  `:noop` пропускается молча: события о том, чего не произошло, не бывает.
  """
  @spec publish(Ecto.UUID.t(), WalletEntry.t() | :noop) :: :ok
  def publish(_user_id, :noop), do: :ok

  def publish(user_id, %WalletEntry{} = entry) do
    announce(user_id, entry.wallet_id, entry)
    :ok
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
        {:ok, %{entry: entry}} -> {:ok, announce(user_id, wallet.id, entry)}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  # Событие уходит **после коммита**, а не внутри транзакции: подписчик,
  # разбуженный на неподтверждённой записи, прочитал бы из базы старый
  # баланс и запомнил его как текущий.
  #
  # Кто слушает — контексту не важно (§3 CLAUDE.md): наружу ядро говорит
  # только фактом, а не вызовом канала.
  defp announce(user_id, wallet_id, %WalletEntry{} = entry) do
    # Баланс перечитывается, а не берётся из `entry.balance_after`: при
    # идемпотентном повторе возвращается **старая** запись, и её баланс
    # давно не текущий. Отправить его — значит своими руками сделать то
    # расхождение, ради которого событие и заводится.
    wallet = Repo.get!(UserWallet, wallet_id)

    # Наружу уходят факты, а не схема журнала: `WalletEntry` не должен
    # утечь в транспорт — там ему делать нечего, и это стережёт
    # `ArchitectureTest`. `entry.amount` знаковый, знак выводить не нужно.
    PubSub.broadcast(
      @pubsub,
      topic(user_id),
      {:wallet_entry,
       %{
         wallet: wallet.type,
         amount: wallet.amount,
         entry: %{
           seq: entry.seq,
           type: entry.type,
           amount: entry.amount,
           ref_id: entry.ref_id,
           at: entry.inserted_at
         }
       }}
    )

    entry
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
         :ok <- ensure_non_negative(wallet, balance_after) do
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

  # Касса рума уходит в минус законно: она источник денег, а не их
  # хранилище. Для всех остальных минус невозможен, и это стережёт БД.
  defp ensure_non_negative(_wallet, balance_after) when balance_after >= 0, do: :ok

  defp ensure_non_negative(%UserWallet{} = wallet, _balance_after) do
    if UserWallet.allows_negative?(wallet), do: :ok, else: {:error, :insufficient_funds}
  end

  defp insert_entry(repo, wallet, attrs, balance_after) do
    changeset =
      %WalletEntry{}
      |> WalletEntry.changeset(Map.put(attrs, :balance_after, balance_after))
      |> WalletEntry.allow_negative(UserWallet.allows_negative?(wallet))

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
