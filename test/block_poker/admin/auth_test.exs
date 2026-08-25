defmodule BlockPoker.Admin.AuthTest do
  @moduledoc """
  Уровень 3: вход в панель на настоящей MySQL под Sandbox.

  Проверяется ровно то, ради чего вход сделан отдельным: игровой токен
  сюда не подходит, админский не подходит в игру, отзыв сессии действует
  немедленно, а «этот email админский» по ответу не выясняется.
  """

  use BlockPoker.DataCase, async: true

  import BlockPoker.AccountsFixtures
  import BlockPoker.AdminFixtures

  alias BlockPoker.Accounts
  alias BlockPoker.Accounts.Tokens
  alias BlockPoker.Admin
  alias BlockPoker.Admin.{AdminAudit, Auth}

  describe "login/3" do
    test "админ получает пару токенов и запись в журнале" do
      admin = admin_fixture()

      assert {:ok, session} =
               Admin.login(admin.email, valid_password(), %{ip: "10.0.0.1", user_agent: "panel"})

      assert is_binary(session.access)
      assert is_binary(session.refresh)
      assert session.admin.id == admin.id

      assert %AdminAudit{action: :login, ip: "10.0.0.1"} =
               Repo.get_by(AdminAudit, admin_id: admin.id, action: :login)
    end

    test "игрок с верным паролем получает тот же invalid_credentials" do
      user = user_fixture()

      assert {:error, :invalid_credentials} =
               Admin.login(user.email, valid_password(), %{ip: "10.0.0.1"})
    end

    test "неудачный вход игрока попадает в журнал как login_failed" do
      user = user_fixture()

      Admin.login(user.email, valid_password(), %{ip: "10.0.0.2"})

      assert %AdminAudit{action: :login_failed, session_id: nil} =
               Repo.get_by(AdminAudit, admin_id: user.id)
    end

    test "заблокированный админ не входит" do
      admin = admin_fixture()
      {:ok, _blocked} = admin |> Ecto.Changeset.change(status: :blocked) |> Repo.update()

      assert {:error, :invalid_credentials} =
               Admin.login(admin.email, valid_password(), %{ip: "10.0.0.1"})
    end
  end

  describe "authorize/1" do
    test "игровой socket-токен в панель не пускает" do
      admin = admin_fixture()

      assert {:error, :token_invalid} = Admin.authorize(Tokens.issue_socket_token(admin))
    end

    test "админский токен не открывает игровой сокет" do
      session = admin_session_fixture()

      assert {:error, :token_invalid} = Accounts.verify_socket_token(session.access)
    end

    test "отозванная сессия перестаёт авторизовывать немедленно" do
      session = admin_session_fixture()

      assert {:ok, _authorized} = Admin.authorize(session.access)

      :ok = Admin.logout(session.session.id)

      assert {:error, :admin_session_expired} = Admin.authorize(session.access)
    end

    test "снятая роль закрывает доступ, хотя токен ещё жив" do
      admin = admin_fixture()
      session = admin_session_fixture(admin)

      {:ok, _demoted} = Accounts.set_role(admin, :default)

      assert {:error, :admin_required} = Admin.authorize(session.access)
    end
  end

  describe "refresh/2" do
    test "выдаёт новую пару и отзывает предъявленный refresh" do
      session = admin_session_fixture()

      assert {:ok, rotated} = Admin.refresh(session.refresh, %{ip: "10.0.0.3"})
      refute rotated.refresh == session.refresh

      # Использованный токен второй раз не работает: ротация означает
      # отзыв, а не «оба живы до истечения».
      assert {:error, :admin_session_expired} = Admin.refresh(session.refresh, %{ip: "10.0.0.3"})
      assert {:ok, _again} = Admin.refresh(rotated.refresh, %{ip: "10.0.0.3"})
    end

    test "чужая строка не проходит" do
      assert {:error, :token_invalid} = Admin.refresh("не токен", %{ip: "10.0.0.3"})
    end
  end

  describe "session_alive?/1" do
    test "отзыв гасит живость сессии" do
      %{ctx: ctx, session: session} = admin_with_ctx()

      assert Admin.session_alive?(ctx)

      :ok = Admin.logout(session.session.id)

      refute Admin.session_alive?(ctx)
    end
  end

  test "ensure_admin/1 отвечает кодом, а не структурой пользователя" do
    user = user_fixture()

    assert {:error, :admin_required} = Auth.ensure_admin(user.id)
    assert {:error, :admin_required} = Auth.ensure_admin(Ecto.UUID.generate())
  end
end
