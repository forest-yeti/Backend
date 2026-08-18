defmodule BlockPoker.Accounts.TokensTest do
  use BlockPoker.DataCase, async: true

  import BlockPoker.AccountsFixtures

  alias BlockPoker.Accounts.{RefreshToken, Tokens}

  describe "socket-токен" do
    test "подписывается и проверяется" do
      user = user_fixture()
      token = Tokens.issue_socket_token(user)

      assert {:ok, user_id} = Tokens.verify_socket_token(token)
      assert user_id == user.id
    end

    test "просроченный токен отвергается" do
      user = user_fixture()
      token = Phoenix.Token.sign(Socket.Endpoint, "user socket", user.id, signed_at: 0)

      assert {:error, :token_expired} = Tokens.verify_socket_token(token)
    end

    test "чужая соль не подходит" do
      user = user_fixture()
      token = Phoenix.Token.sign(Socket.Endpoint, "другая соль", user.id)

      assert {:error, :token_invalid} = Tokens.verify_socket_token(token)
    end
  end

  describe "refresh-токен" do
    test "в БД лежит только хэш" do
      user = user_fixture()
      {:ok, raw} = Tokens.issue_refresh_token(user)

      record = Repo.one!(RefreshToken)

      assert record.token_hash == :crypto.hash(:sha256, raw)
      refute record.token_hash == raw
    end

    test "ротация: старый перестаёт работать, новый работает" do
      user = user_fixture()
      {:ok, raw} = Tokens.issue_refresh_token(user)

      assert {:ok, %{user: refreshed, refresh_token: new_raw}} = Tokens.refresh(raw)
      assert refreshed.id == user.id
      assert new_raw != raw

      # Новый токен работает; предъявление старого сожжёт всю цепочку —
      # это проверяется отдельным тестом.
      assert {:ok, _result} = Tokens.refresh(new_raw)
    end

    test "повторное предъявление отозванного токена отзывает всю цепочку" do
      user = user_fixture()
      {:ok, first} = Tokens.issue_refresh_token(user)
      {:ok, %{refresh_token: second}} = Tokens.refresh(first)

      assert {:error, :token_reused} = Tokens.refresh(first)
      assert {:error, :token_reused} = Tokens.refresh(second)
    end

    test "просроченный токен не проходит" do
      user = user_fixture()
      {:ok, raw} = Tokens.issue_refresh_token(user)

      RefreshToken
      |> Repo.one!()
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :day))
      |> Repo.update!()

      assert {:error, :token_expired} = Tokens.refresh(raw)
    end

    test "неизвестный токен не проходит" do
      assert {:error, :token_invalid} = Tokens.refresh("такого не выдавали")
    end

    test "delete_expired убирает только просроченные" do
      user = user_fixture()
      {:ok, _live} = Tokens.issue_refresh_token(user)
      {:ok, _stale} = Tokens.issue_refresh_token(user)

      RefreshToken
      |> Repo.all()
      |> List.last()
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :day))
      |> Repo.update!()

      assert {1, nil} = Tokens.delete_expired()
      assert Repo.aggregate(RefreshToken, :count) == 1
    end
  end
end
