defmodule Api.Admin.GridControllerTest do
  @moduledoc """
  Уровень 4: сетки режимов по HTTP насквозь — запрос, ядро, JSON.

  Проверяется не «форма ответа», а четыре свойства, ради которых ручки
  вообще существуют: заведённый шаблон появляется в сетке, правка
  доезжает до БД, снятый с сетки не исчезает из неё насовсем, и ни одно
  изменение не проходит мимо журнала.
  """

  use Api.ConnCase, async: true

  import BlockPoker.AdminFixtures
  import BlockPoker.CashGamesFixtures

  alias BlockPoker.Admin.AdminAudit
  alias BlockPoker.CashGames
  alias BlockPoker.Repo

  setup do
    admin_with_ctx()
  end

  defp authed(conn, session) do
    put_req_header(conn, "authorization", "Bearer " <> session.access)
  end

  defp audit_actions do
    AdminAudit |> Repo.all() |> Enum.map(& &1.action)
  end

  describe "GET /admin/settings" do
    test "отдаёт сетку кэша", %{conn: conn, session: session} do
      setting = setting_fixture(%{name: "NL10", small_blind: 5, big_blind: 10})

      conn = conn |> authed(session) |> get("/admin/settings", %{"kind" => "cash"})

      assert %{"items" => items} = json_response(conn, 200)
      assert Enum.any?(items, &(&1["id"] == setting.id and &1["name"] == "NL10"))
    end

    test "неизвестный режим — ошибка, а не пустой список", %{conn: conn, session: session} do
      conn = conn |> authed(session) |> get("/admin/settings", %{"kind" => "backgammon"})

      assert %{"code" => "validation_failed"} = json_response(conn, 422)
    end

    test "без токена не пускает", %{conn: conn} do
      conn = get(conn, "/admin/settings", %{"kind" => "cash"})

      assert json_response(conn, 401)
    end
  end

  describe "POST /admin/settings/:kind" do
    test "заводит кэш-лимит и пишет в журнал", %{conn: conn, session: session} do
      conn =
        conn
        |> authed(session)
        |> post("/admin/settings/cash", %{
          "name" => "NL50",
          "game_type" => "texas_holdem",
          "currency" => "play_money",
          "small_blind" => 25,
          "big_blind" => 50,
          "max_players" => 6,
          "rake_percent" => 50
        })

      assert %{"id" => id, "name" => "NL50", "rake_percent" => 50} = json_response(conn, 201)
      assert {:ok, setting} = CashGames.get_setting(id)
      assert setting.big_blind == 50
      assert :grid_create in audit_actions()
    end

    test "код закрытой комнаты выдаёт сервер", %{conn: conn, session: session} do
      conn =
        conn
        |> authed(session)
        |> post("/admin/settings/cash", %{
          "name" => "Домашняя",
          "game_type" => "texas_holdem",
          "currency" => "play_money",
          "small_blind" => 5,
          "big_blind" => 10,
          "max_players" => 6,
          "visibility" => "private",
          "code" => "хочу_такой"
        })

      assert %{"visibility" => "private", "code" => code} = json_response(conn, 201)
      assert String.length(code) == 6
      refute code == "хочу_такой"
    end

    test "кривой шаблон не заводится и в журнал не попадает", %{conn: conn, session: session} do
      conn =
        conn
        |> authed(session)
        |> post("/admin/settings/cash", %{
          "game_type" => "texas_holdem",
          "currency" => "play_money",
          "small_blind" => 50,
          "big_blind" => 10,
          "max_players" => 6
        })

      assert %{"code" => "validation_failed", "errors" => errors} = json_response(conn, 422)
      assert Map.has_key?(errors, "big_blind")
      refute :grid_create in audit_actions()
    end

    test "заводит турнир вместе с уровнями и сеткой выплат", %{conn: conn, session: session} do
      conn =
        conn
        |> authed(session)
        |> post("/admin/settings/mtt", %{
          "name" => "Вечерний",
          "game_type" => "texas_holdem",
          "currency" => "play_money",
          "buy_in" => 1000,
          "entry_fee" => 100,
          "starting_stack" => 5000,
          "table_size" => 6,
          "min_players" => 2,
          "max_players" => 100,
          "blind_levels" => [
            %{
              "level" => 1,
              "small_blind" => 25,
              "big_blind" => 50,
              "duration_seconds" => 600,
              "rebuy_allowed" => true
            },
            %{
              "level" => 2,
              "small_blind" => 50,
              "big_blind" => 100,
              "duration_seconds" => 600,
              "rebuy_allowed" => false
            }
          ],
          "payout_rows" => [
            %{
              "entries_from" => 2,
              "place_from" => 1,
              "place_to" => 1,
              "share_ppm" => 650_000
            },
            %{
              "entries_from" => 2,
              "place_from" => 2,
              "place_to" => 2,
              "share_ppm" => 350_000
            }
          ],
          "schedules" => [%{"start_time" => "21:30:00", "repeat" => true}]
        })

      assert %{"blind_levels" => levels, "payout_rows" => rows, "schedules" => [schedule]} =
               json_response(conn, 201)

      assert length(levels) == 2
      assert length(rows) == 2
      assert schedule["start_time"] == "21:30:00"
    end

    test "турнир, который нечем закончить, не заводится", %{conn: conn, session: session} do
      conn =
        conn
        |> authed(session)
        |> post("/admin/settings/mtt", %{
          "name" => "Без выплат",
          "game_type" => "texas_holdem",
          "currency" => "play_money",
          "buy_in" => 1000,
          "starting_stack" => 5000,
          "table_size" => 6,
          "min_players" => 2,
          "max_players" => 100,
          "blind_levels" => [
            %{"level" => 1, "small_blind" => 25, "big_blind" => 50, "duration_seconds" => 600}
          ],
          "payout_rows" => []
        })

      assert json_response(conn, 422)
    end
  end

  describe "PATCH /admin/settings/:kind/:id" do
    test "правит поля кэш-лимита", %{conn: conn, session: session} do
      setting = setting_fixture()

      conn =
        conn
        |> authed(session)
        |> patch("/admin/settings/cash/#{setting.id}", %{
          "rake_percent" => 45,
          "felt_color" => "#123456"
        })

      assert %{"rake_percent" => 45, "felt_color" => "#123456"} = json_response(conn, 200)
      assert {:ok, updated} = CashGames.get_setting(setting.id)
      assert updated.rake_percent == 45
      assert :grid_update in audit_actions()
    end

    test "заменяет структуру уровней турнира целиком", %{conn: conn, session: session} do
      setting = setting_fixture_mtt()

      conn =
        conn
        |> authed(session)
        |> patch("/admin/settings/mtt/#{setting.id}", %{
          "blind_levels" => [
            %{
              "level" => 1,
              "small_blind" => 10,
              "big_blind" => 20,
              "duration_seconds" => 300,
              "rebuy_allowed" => false
            }
          ]
        })

      assert %{"blind_levels" => [level]} = json_response(conn, 200)
      assert level["big_blind"] == 20
    end

    test "несуществующий шаблон — 404", %{conn: conn, session: session} do
      conn =
        conn
        |> authed(session)
        |> patch("/admin/settings/cash/#{Ecto.UUID.generate()}", %{"rake_percent" => 10})

      assert %{"code" => "admin_setting_not_found"} = json_response(conn, 404)
    end
  end

  describe "снятие с сетки" do
    test "снятый шаблон уходит из сетки, но остаётся в БД", %{conn: conn, session: session} do
      setting = setting_fixture()

      conn =
        conn
        |> authed(session)
        |> post("/admin/settings/cash/#{setting.id}/archive", %{"reason" => "закрыли лимит"})

      assert %{"archived" => true, "enabled" => false} = json_response(conn, 200)

      # Строка на месте: на неё ссылается история раздач.
      assert {:ok, _still_there} = CashGames.get_setting(setting.id)
      refute Enum.any?(CashGames.list_settings(), &(&1.id == setting.id))
      assert Enum.any?(CashGames.list_settings(archived: true), &(&1.id == setting.id))
      assert :grid_archive in audit_actions()
    end

    test "без причины не снимается", %{conn: conn, session: session} do
      setting = setting_fixture()

      conn =
        conn
        |> authed(session)
        |> post("/admin/settings/cash/#{setting.id}/archive", %{})

      assert %{"code" => "admin_reason_required"} = json_response(conn, 422)
      assert {:ok, %{archived_at: nil}} = CashGames.get_setting(setting.id)
    end

    test "снятые видны отдельным фильтром", %{conn: conn, session: session} do
      setting = setting_fixture()

      conn
      |> authed(session)
      |> post("/admin/settings/cash/#{setting.id}/archive", %{"reason" => "закрыли лимит"})

      conn =
        build_conn()
        |> authed(session)
        |> get("/admin/settings", %{"kind" => "cash", "archived" => "true"})

      assert %{"items" => [%{"id" => id}]} = json_response(conn, 200)
      assert id == setting.id
    end

    test "возврат из архива не включает шаблон сам", %{conn: conn, session: session} do
      setting = setting_fixture()

      build_conn()
      |> authed(session)
      |> post("/admin/settings/cash/#{setting.id}/archive", %{"reason" => "закрыли лимит"})

      conn =
        conn
        |> authed(session)
        |> post("/admin/settings/cash/#{setting.id}/restore", %{})

      assert %{"archived" => false, "enabled" => false} = json_response(conn, 200)
    end
  end

  describe "GET /admin/settings/meta" do
    test "отдаёт справочник и умолчания на каждый режим", %{conn: conn, session: session} do
      conn = conn |> authed(session) |> get("/admin/settings/meta")

      assert %{"kinds" => kinds, "defaults" => defaults, "game_types" => types} =
               json_response(conn, 200)

      assert "cash" in kinds
      assert "mtt" in kinds
      assert "texas_holdem" in types

      # Умолчания приходят из схемы, а не из формы: панель их не сочиняет.
      assert defaults["cash"]["action_timeout_ms"] == 20_000
    end
  end

  # Фикстуры турниров не импортируются: у них своя `setting_fixture/1`,
  # и два одноимённых импорта в одном тесте читались бы как один.
  defp setting_fixture_mtt, do: BlockPoker.TournamentsFixtures.setting_fixture()
end
