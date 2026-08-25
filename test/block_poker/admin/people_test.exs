defmodule BlockPoker.Admin.PeopleTest do
  @moduledoc """
  Уровень 3: люди глазами панели — список, курсор, бан, сверка балансов.
  """

  use BlockPoker.DataCase, async: true

  import BlockPoker.AccountsFixtures
  import BlockPoker.AdminFixtures

  alias BlockPoker.Admin
  alias BlockPoker.Admin.AdminAudit
  alias BlockPoker.Wallet

  setup do
    Map.merge(admin_with_ctx(), %{player: user_fixture()})
  end

  describe "list/1" do
    test "отдаёт балансы обеих валют", %{ctx: ctx, player: player} do
      assert {:ok, page} = Admin.list_users(ctx, %{limit: 100})

      row = Enum.find(page.entries, &(&1.id == player.id))

      assert row.wallets.main == 0
      assert row.wallets.play_money == Wallet.play_money_default()
      assert row.seated_at == []
    end

    test "курсор не дублирует и не теряет строк", %{ctx: ctx} do
      for _index <- 1..5, do: user_fixture()

      assert {:ok, first} = Admin.list_users(ctx, %{limit: 3})
      assert length(first.entries) == 3
      assert first.cursor

      assert {:ok, second} = Admin.list_users(ctx, %{limit: 3, cursor: first.cursor})

      first_ids = Enum.map(first.entries, & &1.id)
      second_ids = Enum.map(second.entries, & &1.id)

      assert first_ids -- second_ids == first_ids
    end

    test "поиск по подстроке ника и email", %{ctx: ctx} do
      needle = "иголка#{System.unique_integer([:positive])}"
      user = user_fixture(%{email: "#{needle}@example.com"})

      assert {:ok, page} = Admin.list_users(ctx, %{q: needle})
      assert [%{id: id}] = page.entries
      assert id == user.id
    end

    test "verify показывает, что кэш сходится с журналом", %{ctx: ctx, player: player} do
      assert {:ok, page} = Admin.list_users(ctx, %{limit: 100, verify: true})

      row = Enum.find(page.entries, &(&1.id == player.id))

      assert row.verify.matches
      assert row.verify.ledger.play_money == row.wallets.play_money
    end

    test "фильтр по статусу", %{ctx: ctx, player: player} do
      {:ok, _banned} = Admin.ban(ctx, player.id, "правила")

      assert {:ok, page} = Admin.list_users(ctx, %{status: :blocked})

      assert Enum.map(page.entries, & &1.id) == [player.id]
    end
  end

  describe "ban/3 и unban/3" do
    test "меняют статус и оставляют по одной записи в журнале", %{ctx: ctx, player: player} do
      assert {:ok, banned} = Admin.ban(ctx, player.id, "мультиаккаунт")
      assert banned.status == :blocked

      assert {:ok, unbanned} = Admin.unban(ctx, player.id, "разобрались")
      assert unbanned.status == :active

      actions =
        AdminAudit
        |> where([a], a.subject_id == ^player.id)
        |> order_by(asc: :inserted_at)
        |> Repo.all()
        |> Enum.map(& &1.action)

      assert actions == [:ban_user, :unban_user]
    end

    test "без причины статус не меняется и журнал пуст", %{ctx: ctx, player: player} do
      assert {:error, :admin_reason_required} = Admin.ban(ctx, player.id, "")

      assert Repo.get!(BlockPoker.Accounts.User, player.id).status == :active
      assert Repo.aggregate(from(a in AdminAudit, where: a.action == :ban_user), :count) == 0
    end

    test "слишком короткая причина не проходит", %{ctx: ctx, player: player} do
      assert {:error, :admin_reason_required} = Admin.ban(ctx, player.id, "ок")
    end

    test "несуществующий игрок — not_found", %{ctx: ctx} do
      assert {:error, :not_found} = Admin.ban(ctx, Ecto.UUID.generate(), "причина")
    end
  end

  describe "user_card/2 и ledger/3" do
    test "карточка показывает историю банов", %{ctx: ctx, player: player} do
      {:ok, _banned} = Admin.ban(ctx, player.id, "мультиаккаунт")

      assert {:ok, card} = Admin.user_card(ctx, player.id)
      assert [%{action: :ban_user, reason: "мультиаккаунт"}] = card.bans
      assert card.verify.matches
    end

    test "выписка отдаёт записи свежими вперёд и валюту каждой", %{ctx: ctx, player: player} do
      {:ok, _credited} =
        Admin.credit(ctx, player.id, :play_money, 4_200, "бонус", idempotency_key())

      assert {:ok, page} = Admin.ledger(ctx, player.id, %{limit: 10})

      assert [%{type: :admin_credit, amount: 4_200, currency: :play_money} | _rest] = page.entries
    end

    test "фильтр выписки по валюте", %{ctx: ctx, player: player} do
      assert {:ok, page} = Admin.ledger(ctx, player.id, %{limit: 10, currency: :main})

      assert page.entries == []
    end
  end

  test "игрок без роли не видит списка" do
    player = user_fixture()
    ctx = %BlockPoker.Admin.Context{admin_id: player.id, session_id: nil, ip: "127.0.0.1"}

    assert {:error, :admin_required} = Admin.list_users(ctx, %{})
    assert {:error, :admin_required} = Admin.user_card(ctx, player.id)
  end
end
