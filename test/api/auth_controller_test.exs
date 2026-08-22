defmodule Api.AuthControllerTest do
  use Api.ConnCase, async: false

  import BlockPoker.AccountsFixtures

  alias BlockPoker.Accounts

  setup do
    Api.RateLimiter.reset()
    :ok
  end

  describe "POST /api/auth/register" do
    test "создаёт игрока и отдаёт токены", %{conn: conn} do
      attrs = valid_user_attrs()

      conn = post(conn, "/api/auth/register", attrs)

      assert %{"token" => token, "refresh_token" => refresh, "user" => user, "wallets" => wallets} =
               json_response(conn, 201)

      assert is_binary(token)
      assert is_binary(refresh)
      assert user["name"] == attrs["name"]
      assert user["email"] == attrs["email"]
      assert user["avatar"] == "First"

      assert Enum.sort_by(wallets, & &1["type"]) == [
               %{"type" => "main", "amount" => 0},
               %{"type" => "play_money", "amount" => 10_000}
             ]
    end

    test "в сыром теле ответа нет ни пароля, ни хэша", %{conn: conn} do
      attrs = valid_user_attrs()
      conn = post(conn, "/api/auth/register", attrs)

      body = response(conn, 201)

      refute body =~ "password"
      refute body =~ "argon2"
      refute body =~ attrs["password"]
    end

    test "невалидные данные — 422 с кодом и разбором по полям", %{conn: conn} do
      conn = post(conn, "/api/auth/register", %{"name" => "a", "email" => "x", "password" => "1"})

      assert %{"code" => "validation_failed", "errors" => errors} = json_response(conn, 422)
      assert errors["name"]
      assert errors["email"]
      assert errors["password"]
    end
  end

  describe "POST /api/auth/login" do
    test "верные данные — 200 и рабочий socket-токен", %{conn: conn} do
      user = user_fixture()

      conn =
        post(conn, "/api/auth/login", %{"email" => user.email, "password" => valid_password()})

      assert %{"token" => token, "expires_in" => 3600} = json_response(conn, 200)
      assert {:ok, verified} = Accounts.verify_socket_token(token)
      assert verified.id == user.id
    end

    test "неверный пароль — 401", %{conn: conn} do
      user = user_fixture()

      conn = post(conn, "/api/auth/login", %{"email" => user.email, "password" => "nope nope"})

      assert %{"code" => "invalid_credentials"} = json_response(conn, 401)
    end

    test "неполный payload — 422", %{conn: conn} do
      conn = post(conn, "/api/auth/login", %{"email" => "a@b.io"})

      assert %{"code" => "validation_failed"} = json_response(conn, 422)
    end

    test "rate limit срабатывает после 10 попыток с одного IP", %{conn: conn} do
      params = %{"email" => "nobody@example.com", "password" => "whatever!"}

      for _attempt <- 1..10 do
        assert conn |> post("/api/auth/login", params) |> json_response(401)
      end

      assert %{"code" => "rate_limited"} =
               conn |> post("/api/auth/login", params) |> json_response(429)
    end
  end

  describe "POST /api/auth/refresh" do
    test "ротация: новая пара токенов, старый refresh больше не работает", %{conn: conn} do
      user = user_fixture()
      {:ok, session} = Accounts.login(user.email, valid_password())

      conn = post(conn, "/api/auth/refresh", %{"refresh_token" => session.refresh_token})

      assert %{"refresh_token" => rotated} = json_response(conn, 200)
      assert rotated != session.refresh_token

      reused =
        build_conn()
        |> post("/api/auth/refresh", %{"refresh_token" => session.refresh_token})

      assert %{"code" => "token_reused"} = json_response(reused, 401)
    end

    test "неизвестный токен — 401", %{conn: conn} do
      conn = post(conn, "/api/auth/refresh", %{"refresh_token" => "такого не выдавали"})

      assert %{"code" => "token_invalid"} = json_response(conn, 401)
    end
  end
end
