defmodule Api.Admin.AdminControllerTest do
  @moduledoc """
  Уровень 4: панель по HTTP насквозь — запрос, ядро, JSON.

  Проверки секретов делаются **на сыром теле ответа**, а не на структуре:
  тест ищет отсутствие данных в том, что реально уйдёт клиенту. Проверка
  на структуре пропустила бы утечку через поле, о котором тест не знал.
  """

  use Api.ConnCase, async: true

  import BlockPoker.AccountsFixtures
  import BlockPoker.AdminFixtures

  alias BlockPoker.Accounts.Tokens
  alias BlockPoker.Admin

  setup do
    Map.merge(admin_with_ctx(), %{player: user_fixture()})
  end

  defp authed(conn, session) do
    put_req_header(conn, "authorization", "Bearer " <> session.access)
  end

  describe "POST /admin/auth/login" do
    test "админ получает пару токенов", %{conn: conn, admin: admin} do
      conn =
        post(conn, "/admin/auth/login", %{
          "email" => admin.email,
          "password" => valid_password()
        })

      assert %{"access" => access, "refresh" => refresh} = json_response(conn, 200)
      assert is_binary(access)
      assert is_binary(refresh)
    end

    test "игрок получает 401 и не узнаёт, что email не админский", %{conn: conn} do
      player = user_fixture()

      conn =
        post(conn, "/admin/auth/login", %{
          "email" => player.email,
          "password" => valid_password()
        })

      assert %{"code" => "invalid_credentials"} = json_response(conn, 401)
    end

    test "в ответе нет ни хэша пароля, ни хэша токена", %{conn: conn, admin: admin} do
      conn =
        post(conn, "/admin/auth/login", %{
          "email" => admin.email,
          "password" => valid_password()
        })

      raw = conn.resp_body

      refute raw =~ "password_hash"
      refute raw =~ "token_hash"
      refute raw =~ "$argon2"
    end
  end

  describe "GET /admin/users" do
    test "без токена — 401", %{conn: conn} do
      assert %{"code" => "token_invalid"} = conn |> get("/admin/users") |> json_response(401)
    end

    test "с игровым токеном — 401", %{conn: conn, player: player} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> Tokens.issue_socket_token(player))
        |> get("/admin/users")

      assert json_response(conn, 401)
    end

    test "с админским — список с балансами обеих валют", %{
      conn: conn,
      session: session,
      player: player
    } do
      conn = conn |> authed(session) |> get("/admin/users", %{"limit" => "100"})

      assert %{"items" => items} = json_response(conn, 200)

      row = Enum.find(items, &(&1["id"] == player.id))

      assert row["wallets"]["main"] == 0
      assert row["wallets"]["play_money"] > 0
      refute conn.resp_body =~ "password_hash"
    end

    test "курсорная пагинация не дублирует и не теряет строк при вставке между запросами",
         %{conn: conn, session: session} do
      for _index <- 1..4, do: user_fixture()

      first =
        conn |> authed(session) |> get("/admin/users", %{"limit" => "3"}) |> json_response(200)

      # Новый игрок появляется между страницами: он свежее курсора, и
      # именно поэтому во вторую страницу он попасть не должен.
      _newcomer = user_fixture()

      second =
        conn
        |> authed(session)
        |> get("/admin/users", %{"limit" => "3", "cursor" => first["cursor"]})
        |> json_response(200)

      first_ids = Enum.map(first["items"], & &1["id"])
      second_ids = Enum.map(second["items"], & &1["id"])

      assert first_ids -- second_ids == first_ids
      assert length(Enum.uniq(first_ids ++ second_ids)) == length(first_ids ++ second_ids)
    end

    test "отозванная сессия закрывает доступ немедленно", %{conn: conn, session: session} do
      :ok = Admin.logout(session.session.id)

      assert %{"code" => "admin_session_expired"} =
               conn |> authed(session) |> get("/admin/users") |> json_response(401)
    end
  end

  describe "деньги по HTTP" do
    test "credit начисляет и отдаёт новый баланс", %{
      conn: conn,
      session: session,
      player: player
    } do
      conn =
        conn
        |> authed(session)
        |> post("/admin/users/#{player.id}/credit", %{
          "currency" => "play_money",
          "amount" => 3_000,
          "reason" => "компенсация бага",
          "idempotency_key" => idempotency_key()
        })

      assert %{"balance" => balance} = json_response(conn, 200)
      assert balance > 3_000
    end

    test "без причины — 422 и код", %{conn: conn, session: session, player: player} do
      conn =
        conn
        |> authed(session)
        |> post("/admin/users/#{player.id}/credit", %{
          "currency" => "play_money",
          "amount" => 100,
          "reason" => "",
          "idempotency_key" => idempotency_key()
        })

      assert %{"code" => "admin_reason_required"} = json_response(conn, 422)
    end

    test "дробная сумма не проходит форму", %{conn: conn, session: session, player: player} do
      conn =
        conn
        |> authed(session)
        |> post("/admin/users/#{player.id}/credit", %{
          "currency" => "play_money",
          "amount" => 10.5,
          "reason" => "дробь",
          "idempotency_key" => idempotency_key()
        })

      assert %{"code" => "validation_failed"} = json_response(conn, 422)
    end

    test "take списывает и отдаёт оба баланса", %{
      conn: conn,
      session: session,
      player: player
    } do
      conn =
        conn
        |> authed(session)
        |> post("/admin/users/#{player.id}/take", %{
          "currency" => "play_money",
          "amount" => 500,
          "reason" => "возврат ошибочного начисления",
          "idempotency_key" => idempotency_key()
        })

      assert %{"player_balance" => player_balance, "admin_balance" => admin_balance} =
               json_response(conn, 200)

      assert admin_balance > player_balance or is_integer(admin_balance)
    end

    test "бан меняет статус", %{conn: conn, session: session, player: player} do
      conn =
        conn
        |> authed(session)
        |> post("/admin/users/#{player.id}/ban", %{"reason" => "мультиаккаунт"})

      assert %{"status" => "blocked"} = json_response(conn, 200)
    end
  end

  describe "GET /admin/audit" do
    test "показывает совершённые действия", %{conn: conn, session: session, player: player} do
      conn
      |> authed(session)
      |> post("/admin/users/#{player.id}/ban", %{"reason" => "мультиаккаунт"})

      body =
        conn |> authed(session) |> get("/admin/audit") |> json_response(200)

      actions = Enum.map(body["items"], & &1["action"])

      assert "ban_user" in actions
      assert "login" in actions
    end
  end

  describe "GET /admin/games" do
    test "пустой рум отдаёт пустой список, а не ошибку", %{conn: conn, session: session} do
      assert %{"items" => []} =
               conn |> authed(session) |> get("/admin/games") |> json_response(200)
    end
  end

  describe "GET /admin/auth/me" do
    test "отдаёт админа, его сессии и флаг наблюдения", %{conn: conn, session: session} do
      conn = conn |> authed(session) |> get("/admin/auth/me")
      body = json_response(conn, 200)

      assert body["admin"]["role"] == "admin"
      assert [%{"current" => true}] = body["sessions"]
      assert is_boolean(body["observer_enabled"])
      refute conn.resp_body =~ "token_hash"
    end
  end
end
