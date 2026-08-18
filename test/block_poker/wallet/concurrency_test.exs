defmodule BlockPoker.Wallet.ConcurrencyTest do
  @moduledoc """
  Гонка двух списаний с одного кошелька. Sandbox в режиме `:shared`, поэтому
  тест `async: false` (§11 CLAUDE.md).
  """

  use BlockPoker.DataCase, async: false

  import BlockPoker.AccountsFixtures

  alias BlockPoker.Wallet
  alias BlockPoker.Wallet.UserWallet
  alias Ecto.Multi

  @tag :integration
  test "два параллельных списания не уводят баланс в минус" do
    user = user_fixture()
    {:ok, wallet} = Wallet.get_wallet(user.id, :play_money)

    # Каждое списание по отдельности проходит проверку, вместе — нет.
    debit = fn key ->
      Multi.new()
      |> Wallet.record_entry(:entry, %{
        wallet_id: wallet.id,
        amount: -6_000,
        type: :buy_in,
        idempotency_key: key
      })
      |> Repo.transaction()
    end

    results =
      ["buyin:left", "buyin:right"]
      |> Enum.map(fn key -> Task.async(fn -> debit.(key) end) end)
      |> Task.await_many(5_000)

    assert Enum.count(results, &match?({:ok, _changes}, &1)) == 1
    assert Enum.count(results, &match?({:error, :entry, :insufficient_funds, _c}, &1)) == 1

    assert Repo.get!(UserWallet, wallet.id).amount == 4_000
  end
end
