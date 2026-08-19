defmodule Socket.Channels.WalletChannelTest do
  @moduledoc """
  Канал кошелька насквозь: движение денег в ядре → push игроку.

  Главное, что здесь проверяется, — расхождение экрана с базой больше не
  копится: после бай-ина клиент узнаёт новый баланс, не переспрашивая.
  """

  use Socket.ChannelCase, async: false

  import BlockPoker.AccountsFixtures

  alias BlockPoker.Wallet
  alias Socket.UserSocket

  defp token(user) do
    {:ok, %{token: token}} = BlockPoker.Accounts.start_session(user)
    token
  end

  defp connect_wallet(user) do
    {:ok, socket} = connect(UserSocket, %{"token" => token(user)})
    subscribe_and_join(socket, "wallet:#{user.id}", %{})
  end

  defp play_money(user) do
    {:ok, wallet} = Wallet.get_wallet(user.id, :play_money)
    wallet.amount
  end

  describe "join" do
    test "отдаёт снапшот обоих кошельков" do
      user = user_fixture()

      {:ok, reply, _channel} = connect_wallet(user)

      assert %{wallets: wallets} = reply
      assert Enum.sort(Enum.map(wallets, & &1.type)) == [:main, :play_money]
      assert Enum.find(wallets, &(&1.type == :play_money)).amount == Wallet.play_money_default()
    end

    test "на чужой кошелёк подписаться нельзя" do
      user = user_fixture()
      stranger = user_fixture()

      {:ok, socket} = connect(UserSocket, %{"token" => token(user)})

      assert {:error, %{code: "not_found"}} =
               subscribe_and_join(socket, "wallet:#{stranger.id}", %{})
    end
  end

  describe "движение денег" do
    test "бай-ин доезжает до клиента новым балансом" do
      user = user_fixture()
      {:ok, _reply, _channel} = connect_wallet(user)

      {:ok, _entry} = Wallet.buy_in(user.id, :play_money, 400, "buyin:#{Ecto.UUID.generate()}")

      assert_push "wallet_entry", payload
      assert payload.wallet == :play_money
      assert payload.amount == Wallet.play_money_default() - 400
      assert payload.entry.type == :buy_in

      # Знак берётся из записи: клиенту незачем выводить его из типа.
      assert payload.entry.amount == -400
    end

    test "кэш-аут возвращает баланс тем же путём" do
      user = user_fixture()
      {:ok, _reply, _channel} = connect_wallet(user)
      {:ok, _entry} = Wallet.buy_in(user.id, :play_money, 400, "buyin:#{Ecto.UUID.generate()}")
      assert_push "wallet_entry", _payload

      {:ok, _entry} =
        Wallet.cash_out(user.id, :play_money, 550, "cashout:#{Ecto.UUID.generate()}")

      assert_push "wallet_entry", payload
      assert payload.amount == Wallet.play_money_default() - 400 + 550
      assert payload.entry.type == :cash_out
    end

    test "повторный вызов с тем же ключом шлёт текущий баланс, а не старый" do
      user = user_fixture()
      {:ok, _reply, _channel} = connect_wallet(user)
      key = "buyin:#{Ecto.UUID.generate()}"

      {:ok, _entry} = Wallet.buy_in(user.id, :play_money, 400, key)
      assert_push "wallet_entry", _payload
      {:ok, _entry} = Wallet.buy_in(user.id, :play_money, 100, "buyin:#{Ecto.UUID.generate()}")
      assert_push "wallet_entry", _payload

      # Ретрай возвращает запись первого списания: её `balance_after` давно
      # неактуален, и отправить его — значит вернуть ровно то расхождение,
      # ради которого канал и заведён.
      {:ok, _entry} = Wallet.buy_in(user.id, :play_money, 400, key)

      assert_push "wallet_entry", payload
      assert payload.amount == play_money(user)
      assert payload.amount == Wallet.play_money_default() - 500
    end

    test "отказ по деньгам события не порождает" do
      user = user_fixture()
      {:ok, _reply, _channel} = connect_wallet(user)

      assert {:error, :insufficient_funds} =
               Wallet.buy_in(user.id, :play_money, 999_999, "buyin:#{Ecto.UUID.generate()}")

      refute_push "wallet_entry", _payload
    end

    test "чужое движение денег в топик не приходит" do
      user = user_fixture()
      stranger = user_fixture()
      {:ok, _reply, _channel} = connect_wallet(user)

      {:ok, _entry} =
        Wallet.buy_in(stranger.id, :play_money, 400, "buyin:#{Ecto.UUID.generate()}")

      refute_push "wallet_entry", _payload
    end
  end

  describe "перезапрос" do
    test "balance отдаёт актуальные суммы" do
      user = user_fixture()
      {:ok, _reply, channel} = connect_wallet(user)
      {:ok, _entry} = Wallet.buy_in(user.id, :play_money, 400, "buyin:#{Ecto.UUID.generate()}")

      ref = push(channel, "balance", %{})

      assert_reply ref, :ok, %{wallets: wallets}
      assert Enum.find(wallets, &(&1.type == :play_money)).amount == play_money(user)
    end
  end
end
