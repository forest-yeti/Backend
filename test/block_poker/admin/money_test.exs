defmodule BlockPoker.Admin.MoneyTest do
  @moduledoc """
  Уровень 3: деньги панели на настоящей MySQL под Sandbox.

  База здесь не мокается принципиально (§11 CLAUDE.md): половина гарантий
  — это UNIQUE на `idempotency_key`, `check_constraint` неотрицательного
  баланса и откат транзакции. Мок этих правил проверял бы мок.
  """

  use BlockPoker.DataCase, async: true

  import BlockPoker.AccountsFixtures
  import BlockPoker.AdminFixtures

  alias BlockPoker.Admin
  alias BlockPoker.Admin.AdminAudit
  alias BlockPoker.Wallet
  alias BlockPoker.Wallet.{UserWallet, WalletEntry}

  setup do
    Map.merge(admin_with_ctx(), %{player: user_fixture()})
  end

  # Сумма всех записей журнала по всем кошелькам — то самое «сколько
  # фишек в системе», которое админские операции менять не вправе.
  defp total_chips do
    case Repo.aggregate(WalletEntry, :sum, :amount) do
      nil -> 0
      %Decimal{} = sum -> Decimal.to_integer(sum)
      sum -> sum
    end
  end

  defp balance(user_id, currency) do
    {:ok, wallet} = Wallet.get_wallet(user_id, currency)
    wallet.amount
  end

  describe "credit/6" do
    test "начисляет и оставляет ровно одну запись в журнале действий", %{
      ctx: ctx,
      player: player
    } do
      before = balance(player.id, :play_money)

      assert {:ok, result} =
               Admin.credit(ctx, player.id, :play_money, 5_000, "компенсация", idempotency_key())

      assert result.balance == before + 5_000
      assert balance(player.id, :play_money) == before + 5_000

      assert [%AdminAudit{action: :credit, amount: 5_000, reason: "компенсация"}] =
               Repo.all(from a in AdminAudit, where: a.action == :credit)
    end

    test "тот же idempotency_key дважды создаёт одну запись ledger", %{
      ctx: ctx,
      player: player
    } do
      key = idempotency_key()
      before = balance(player.id, :play_money)

      assert {:ok, _first} = Admin.credit(ctx, player.id, :play_money, 1_000, "бонус", key)
      assert {:ok, second} = Admin.credit(ctx, player.id, :play_money, 1_000, "бонус", key)

      assert second.repeated
      assert balance(player.id, :play_money) == before + 1_000

      entries = Repo.all(from e in WalletEntry, where: e.type == :admin_credit)
      assert length(entries) == 1

      # И вторая запись журнала действий тоже не появилась: операции не
      # было, значит и записывать нечего.
      assert Repo.aggregate(from(a in AdminAudit, where: a.action == :credit), :count) == 1
    end

    test "без причины не начисляет и не пишет ни ledger, ни аудит", %{ctx: ctx, player: player} do
      before = balance(player.id, :play_money)

      assert {:error, :admin_reason_required} =
               Admin.credit(ctx, player.id, :play_money, 1_000, "", idempotency_key())

      assert balance(player.id, :play_money) == before
      assert Repo.aggregate(from(e in WalletEntry, where: e.type == :admin_credit), :count) == 0
      assert Repo.aggregate(from(a in AdminAudit, where: a.action == :credit), :count) == 0
    end

    test "себе начислить нельзя", %{ctx: ctx, admin: admin} do
      assert {:error, :admin_self_target} =
               Admin.credit(ctx, admin.id, :play_money, 100, "себе", idempotency_key())
    end

    test "нулевая и отрицательная сумма отвергаются", %{ctx: ctx, player: player} do
      assert {:error, :admin_amount_invalid} =
               Admin.credit(ctx, player.id, :play_money, 0, "ноль", idempotency_key())

      assert {:error, :admin_amount_invalid} =
               Admin.credit(ctx, player.id, :play_money, -100, "минус", idempotency_key())
    end
  end

  describe "take_to_admin/6" do
    test "перевод не меняет сумму фишек в системе", %{ctx: ctx, admin: admin, player: player} do
      before_total = total_chips()
      player_before = balance(player.id, :play_money)
      admin_before = balance(admin.id, :play_money)

      assert {:ok, result} =
               Admin.take_to_admin(ctx, player.id, :play_money, 2_500, "штраф", idempotency_key())

      assert result.player_balance == player_before - 2_500
      assert result.admin_balance == admin_before + 2_500
      assert total_chips() == before_total
    end

    test "обе записи ссылаются на одну запись журнала действий", %{ctx: ctx, player: player} do
      assert {:ok, result} =
               Admin.take_to_admin(ctx, player.id, :play_money, 700, "штраф", idempotency_key())

      entries = Repo.all(from e in WalletEntry, where: e.type == :admin_transfer)

      assert length(entries) == 2
      assert Enum.all?(entries, &(&1.ref_id == result.audit_id))
      assert entries |> Enum.map(& &1.amount) |> Enum.sum() == 0
    end

    test "списать больше, чем в кошельке, нельзя и следов не остаётся", %{
      ctx: ctx,
      player: player
    } do
      too_much = balance(player.id, :play_money) + 1

      assert {:error, :admin_insufficient_funds} =
               Admin.take_to_admin(
                 ctx,
                 player.id,
                 :play_money,
                 too_much,
                 "штраф",
                 idempotency_key()
               )

      assert Repo.aggregate(from(e in WalletEntry, where: e.type == :admin_transfer), :count) == 0

      assert Repo.aggregate(from(a in AdminAudit, where: a.action == :debit_to_admin), :count) ==
               0
    end

    test "повтор по тому же ключу денег второй раз не двигает", %{ctx: ctx, player: player} do
      key = idempotency_key()
      before = balance(player.id, :play_money)

      assert {:ok, _first} = Admin.take_to_admin(ctx, player.id, :play_money, 300, "штраф", key)
      assert {:ok, second} = Admin.take_to_admin(ctx, player.id, :play_money, 300, "штраф", key)

      assert second.repeated
      assert balance(player.id, :play_money) == before - 300
      assert Repo.aggregate(from(e in WalletEntry, where: e.type == :admin_transfer), :count) == 2
    end

    test "кошелёк игрока не уходит в минус даже на границе", %{ctx: ctx, player: player} do
      whole = balance(player.id, :play_money)

      assert {:ok, _result} =
               Admin.take_to_admin(ctx, player.id, :play_money, whole, "всё", idempotency_key())

      assert balance(player.id, :play_money) == 0

      assert Repo.aggregate(
               from(w in UserWallet, where: w.amount < 0 and w.system == false),
               :count
             ) == 0
    end
  end

  test "игрок без роли не может ничего, даже с валидным контекстом", %{player: player} do
    ctx = %BlockPoker.Admin.Context{admin_id: player.id, session_id: nil, ip: "127.0.0.1"}
    other = user_fixture()

    assert {:error, :admin_required} =
             Admin.credit(ctx, other.id, :play_money, 100, "мимо", idempotency_key())

    assert {:error, :admin_required} =
             Admin.take_to_admin(ctx, other.id, :play_money, 100, "мимо", idempotency_key())
  end
end
