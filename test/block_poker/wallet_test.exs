defmodule BlockPoker.WalletTest do
  use BlockPoker.DataCase, async: true

  import BlockPoker.AccountsFixtures

  alias BlockPoker.Wallet
  alias BlockPoker.Wallet.{UserWallet, WalletEntry}
  alias Ecto.Multi

  setup do
    user = user_fixture()
    {:ok, wallet} = Wallet.get_wallet(user.id, :play_money)
    %{user: user, wallet: wallet}
  end

  defp record(attrs) do
    Multi.new()
    |> Wallet.record_entry(:entry, attrs)
    |> Repo.transaction()
  end

  defp ledger_sum(wallet_id) do
    WalletEntry
    |> where(wallet_id: ^wallet_id)
    |> Repo.aggregate(:sum, :amount)
    |> case do
      nil -> 0
      %Decimal{} = sum -> Decimal.to_integer(sum)
      sum -> sum
    end
  end

  test "списание уменьшает баланс и пишет запись", %{wallet: wallet} do
    assert {:ok, %{entry: entry}} =
             record(%{
               wallet_id: wallet.id,
               amount: -2_000,
               type: :buy_in,
               ref_id: "table-7",
               idempotency_key: "buyin:1"
             })

    assert entry.balance_after == 8_000
    assert Repo.get!(UserWallet, wallet.id).amount == 8_000
  end

  test "инвариант: amount == SUM(entries.amount)", %{user: user, wallet: wallet} do
    {:ok, _result} =
      record(%{wallet_id: wallet.id, amount: -2_000, type: :buy_in, idempotency_key: "buyin:2"})

    {:ok, _result} =
      record(%{
        wallet_id: wallet.id,
        amount: 3_500,
        type: :cash_out,
        idempotency_key: "cashout:2"
      })

    for wallet <- Wallet.list_wallets(user.id) do
      assert wallet.amount == ledger_sum(wallet.id)
    end
  end

  test "идемпотентность: повтор с тем же ключом не создаёт вторую строку", %{wallet: wallet} do
    attrs = %{wallet_id: wallet.id, amount: -500, type: :buy_in, idempotency_key: "buyin:same"}

    {:ok, %{entry: first}} = record(attrs)
    {:ok, %{entry: second}} = record(attrs)

    assert first.id == second.id
    assert Repo.get!(UserWallet, wallet.id).amount == 9_500
    assert length(Wallet.list_entries(wallet.id)) == 2
  end

  test "дубль ключа ловится констрейнтом БД, а не предварительным SELECT", %{wallet: wallet} do
    {:ok, _result} =
      record(%{wallet_id: wallet.id, amount: -500, type: :buy_in, idempotency_key: "buyin:db"})

    changeset =
      WalletEntry.changeset(%WalletEntry{}, %{
        wallet_id: wallet.id,
        amount: -100,
        type: :buy_in,
        balance_after: 9_400,
        idempotency_key: "buyin:db"
      })

    assert {:error, changeset} = Repo.insert(changeset)
    assert %{idempotency_key: ["has already been taken"]} = errors_on(changeset)
  end

  test "списание больше баланса отклоняется", %{wallet: wallet} do
    assert {:error, :entry, :insufficient_funds, _changes} =
             record(%{
               wallet_id: wallet.id,
               amount: -10_001,
               type: :buy_in,
               idempotency_key: "buyin:too-much"
             })

    assert Repo.get!(UserWallet, wallet.id).amount == 10_000
    assert length(Wallet.list_entries(wallet.id)) == 1
  end

  test "нулевая операция запрещена", %{wallet: wallet} do
    assert {:error, :entry, %Ecto.Changeset{}, _changes} =
             record(%{
               wallet_id: wallet.id,
               amount: 0,
               type: :adjustment,
               idempotency_key: "zero"
             })
  end

  test "неизвестный кошелёк", %{} do
    assert {:error, :entry, :not_found, _changes} =
             record(%{
               wallet_id: Ecto.UUID.generate(),
               amount: 100,
               type: :deposit,
               idempotency_key: "ghost"
             })
  end

  test "выписка отсортирована свежими вперёд", %{wallet: wallet} do
    for key <- ["buyin:a", "buyin:b", "buyin:c"] do
      {:ok, _result} =
        record(%{wallet_id: wallet.id, amount: -100, type: :buy_in, idempotency_key: key})
    end

    keys = wallet.id |> Wallet.list_entries() |> Enum.map(& &1.idempotency_key)

    # Первой записью кошелька был стартовый deposit — он же последний в выписке.
    assert ["buyin:c", "buyin:b", "buyin:a", _signup] = keys
  end

  test "порядок выписки не зависит от совпадения времени вставки", %{wallet: wallet} do
    for key <- ["buyin:a", "buyin:b", "buyin:c"] do
      {:ok, _result} =
        record(%{wallet_id: wallet.id, amount: -100, type: :buy_in, idempotency_key: key})
    end

    # Часы грубее микросекунды — обычное дело (на Windows особенно), и тогда
    # у нескольких записей `inserted_at` совпадает. Порядок журнала обязан
    # остаться прежним: его задаёт `seq`, а не время.
    same_time = DateTime.utc_now()

    {_count, _rows} =
      WalletEntry
      |> where(wallet_id: ^wallet.id)
      |> Repo.update_all(set: [inserted_at: same_time])

    keys = wallet.id |> Wallet.list_entries() |> Enum.map(& &1.idempotency_key)

    assert ["buyin:c", "buyin:b", "buyin:a", _signup] = keys
  end

  test "seq выдаёт база, и он растёт с каждой записью", %{wallet: wallet} do
    for key <- ["buyin:a", "buyin:b"] do
      {:ok, _result} =
        record(%{wallet_id: wallet.id, amount: -100, type: :buy_in, idempotency_key: key})
    end

    # Номер приходит из БД, поэтому читается он из выписки, а не из
    # структуры, вернувшейся из вставки.
    seqs = wallet.id |> Wallet.list_entries() |> Enum.map(& &1.seq)

    assert Enum.all?(seqs, &is_integer/1)
    assert seqs == Enum.sort(seqs, :desc)
    assert length(Enum.uniq(seqs)) == length(seqs)
  end

  test "get_wallet возвращает :not_found для чужого пользователя" do
    assert {:error, :not_found} = Wallet.get_wallet(Ecto.UUID.generate(), :main)
  end
end
