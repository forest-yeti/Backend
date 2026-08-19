defmodule BlockPoker.AccountsTest do
  use BlockPoker.DataCase, async: true

  import BlockPoker.AccountsFixtures

  alias BlockPoker.Accounts
  alias BlockPoker.Accounts.User
  alias BlockPoker.Wallet
  alias BlockPoker.Wallet.{UserWallet, WalletEntry}

  describe "register/1" do
    test "создаёт пользователя и ровно два кошелька с дефолтными суммами" do
      {:ok, user} = Accounts.register(valid_user_attrs())

      wallets = Wallet.list_wallets(user.id)

      assert length(wallets) == 2
      assert Enum.map(wallets, & &1.type) |> Enum.sort() == [:main, :play_money]

      assert %UserWallet{amount: 0} = Enum.find(wallets, &(&1.type == :main))
      assert %UserWallet{amount: 10_000} = Enum.find(wallets, &(&1.type == :play_money))
    end

    test "play_money заводится записью deposit, main — с пустым журналом" do
      {:ok, user} = Accounts.register(valid_user_attrs())

      {:ok, play_money} = Wallet.get_wallet(user.id, :play_money)
      {:ok, main} = Wallet.get_wallet(user.id, :main)

      assert [%WalletEntry{} = entry] = Wallet.list_entries(play_money.id)
      assert entry.amount == 10_000
      assert entry.type == :deposit
      assert entry.balance_after == 10_000
      assert entry.idempotency_key == "signup:#{user.id}"

      assert Wallet.list_entries(main.id) == []
    end

    test "падение шага Multi не оставляет ни пользователя, ни кошельков" do
      existing = user_fixture()

      assert {:error, changeset} =
               Accounts.register(valid_user_attrs(%{name: existing.name}))

      refute changeset.valid?
      assert Repo.aggregate(User, :count) == 1
      assert Repo.aggregate(UserWallet, :count) == 2
    end

    test "email нормализуется в нижний регистр" do
      {:ok, user} = Accounts.register(valid_user_attrs(%{email: "MiXeD@Example.IO"}))

      assert user.email == "mixed@example.io"
    end

    test "пароль в БД не хранится" do
      user = user_fixture()

      assert is_nil(user.password)
      assert String.starts_with?(user.password_hash, "$argon2")
      refute inspect(user) =~ user.password_hash
    end

    test "аватар по умолчанию" do
      assert user_fixture().avatar == "/users/avatars/default.png"
    end

    test "невалидные данные отвергаются changeset'ом" do
      assert {:error, changeset} =
               Accounts.register(%{"name" => "ab", "email" => "no-at", "password" => "short"})

      errors = errors_on(changeset)

      assert errors[:name]
      assert errors[:email]
      assert errors[:password]
    end
  end

  describe "уникальность на уровне БД" do
    test "Player и player — два разных пользователя (collation чувствительна к регистру)" do
      email_one = unique_email()
      email_two = unique_email()

      assert {:ok, upper} =
               Accounts.register(%{
                 "name" => "Player",
                 "email" => email_one,
                 "password" => valid_password()
               })

      assert {:ok, lower} =
               Accounts.register(%{
                 "name" => "player",
                 "email" => email_two,
                 "password" => valid_password()
               })

      assert upper.id != lower.id
    end

    test "точный дубликат ника отвергается базой, а не только changeset'ом" do
      user = user_fixture()

      # Обходим предварительный SELECT, чтобы сработал именно UNIQUE-индекс.
      changeset =
        User.registration_changeset(
          %User{},
          %{"name" => user.name, "email" => unique_email(), "password" => valid_password()},
          validate_unique: false
        )

      assert {:error, changeset} = Repo.insert(changeset)
      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end

    test "дубликат email в другом регистре отвергается базой" do
      {:ok, _user} = Accounts.register(valid_user_attrs(%{email: "A@x.io"}))

      changeset =
        User.registration_changeset(
          %User{},
          %{"name" => unique_name(), "email" => "a@x.io", "password" => valid_password()},
          validate_unique: false
        )

      assert {:error, changeset} = Repo.insert(changeset)
      assert %{email: ["has already been taken"]} = errors_on(changeset)
    end

    test "второй кошелёк того же типа ловится UNIQUE-констрейнтом" do
      user = user_fixture()

      changeset =
        UserWallet.changeset(%UserWallet{}, %{user_id: user.id, type: :main, amount: 0})

      assert {:error, changeset} = Repo.insert(changeset)
      assert errors_on(changeset)[:user_id] || errors_on(changeset)[:type]
    end
  end

  describe "authenticate/2" do
    test "верный пароль" do
      user = user_fixture()

      assert {:ok, authenticated} = Accounts.authenticate(user.email, valid_password())
      assert authenticated.id == user.id
    end

    test "email сравнивается без учёта регистра" do
      user = user_fixture()

      assert {:ok, _user} = Accounts.authenticate(String.upcase(user.email), valid_password())
    end

    test "неверный пароль" do
      user = user_fixture()

      assert {:error, :invalid_credentials} = Accounts.authenticate(user.email, "wrong password")
    end

    test "несуществующий email" do
      assert {:error, :invalid_credentials} =
               Accounts.authenticate("nobody@example.com", valid_password())
    end

    test "заблокированный пользователь" do
      user = user_fixture()
      {:ok, _user} = user |> Ecto.Changeset.change(status: :blocked) |> Repo.update()

      assert {:error, :user_blocked} = Accounts.authenticate(user.email, valid_password())
    end
  end

  describe "get_user/1" do
    test "находит по id" do
      user = user_fixture()

      assert {:ok, found} = Accounts.get_user(user.id)
      assert found.id == user.id
    end

    test "мусорный id — :not_found, а не падение" do
      assert {:error, :not_found} = Accounts.get_user("не uuid")
      assert {:error, :not_found} = Accounts.get_user(Ecto.UUID.generate())
    end
  end

  describe "сессии" do
    test "register_session отдаёт пару токенов и кошельки" do
      assert {:ok, session} = Accounts.register_session(valid_user_attrs())

      assert is_binary(session.token)
      assert is_binary(session.refresh_token)
      assert session.expires_in == 3600
      assert length(session.wallets) == 2
    end

    test "login отдаёт сессию, по токену пускает в сокет" do
      user = user_fixture()

      assert {:ok, session} = Accounts.login(user.email, valid_password())
      assert {:ok, verified} = Accounts.verify_socket_token(session.token)
      assert verified.id == user.id
    end

    test "заблокированный пользователь не проходит по валидному токену" do
      user = user_fixture()
      {:ok, session} = Accounts.login(user.email, valid_password())
      {:ok, _user} = user |> Ecto.Changeset.change(status: :blocked) |> Repo.update()

      assert {:error, :user_blocked} = Accounts.verify_socket_token(session.token)
    end

    test "подделанный токен не проходит" do
      assert {:error, :token_invalid} = Accounts.verify_socket_token("не токен")
    end
  end

  describe "роли" do
    test "новый пользователь — обычный игрок" do
      assert %User{role: :default} = user_fixture()
    end

    test "set_role/2 назначает и снимает администратора" do
      user = user_fixture()

      assert {:ok, %User{role: :admin} = admin} = Accounts.set_role(user, "admin")
      assert User.admin?(admin)

      assert {:ok, %User{role: :default} = plain} = Accounts.set_role(admin, :default)
      refute User.admin?(plain)
    end

    test "неизвестная роль не сохраняется" do
      assert {:error, changeset} = user_fixture() |> Accounts.set_role("owner")
      assert %{role: [_message]} = errors_on(changeset)
    end

    test "find_user/1 находит по email и по нику" do
      user = user_fixture()

      assert {:ok, found} = Accounts.find_user(user.email)
      assert found.id == user.id

      assert {:ok, found} = Accounts.find_user(user.name)
      assert found.id == user.id

      assert {:error, :not_found} = Accounts.find_user("никого")
    end
  end
end
