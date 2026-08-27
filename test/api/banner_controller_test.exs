defmodule Api.BannerControllerTest do
  @moduledoc """
  Уровень 4: баннеры по HTTP насквозь — multipart из панели, ядро, JSON
  клиенту.
  """

  use Api.ConnCase, async: false

  import BlockPoker.AdminFixtures

  alias BlockPoker.Banners

  # Минимальный настоящий PNG: сигнатура проверяется по содержимому, и
  # подсунуть текст с расширением `.png` не должно получаться.
  @png <<0x89, "PNG\r\n", 0x1A, "\n", 0::size(64)>>

  setup do
    dir = Path.join(System.tmp_dir!(), "banners_http_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    previous = Application.get_env(:block_poker, :banners, [])
    Application.put_env(:block_poker, :banners, dir: dir, base_url: "https://cdn.example/banners")

    on_exit(fn ->
      Application.put_env(:block_poker, :banners, previous)
      File.rm_rf(dir)
    end)

    Map.merge(admin_with_ctx(), %{dir: dir})
  end

  defp authed(conn, session),
    do: put_req_header(conn, "authorization", "Bearer " <> session.access)

  defp upload(contents \\ @png, name \\ "promo.png") do
    path = Path.join(System.tmp_dir!(), "banner_upload_#{System.unique_integer([:positive])}")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)

    %Plug.Upload{path: path, filename: name, content_type: "image/png"}
  end

  describe "POST /admin/banners" do
    test "кладёт баннер на место и отдаёт готовый адрес картинки", %{
      conn: conn,
      session: session
    } do
      conn =
        conn
        |> authed(session)
        |> post("/admin/banners", %{
          "place" => "CashGameLobbyTop",
          "helper" => "Новые столы",
          "link" => "https://example.com/promo",
          "image" => upload()
        })

      assert %{
               "place" => "CashGameLobbyTop",
               "helper" => "Новые столы",
               "link" => "https://example.com/promo",
               "image" => image
             } = json_response(conn, 200)

      assert String.starts_with?(image, "https://cdn.example/banners/CashGameLobbyTop-")
      assert String.ends_with?(image, ".png")
    end

    test "повторная отправка заменяет баннер, а не заводит второй", %{
      conn: conn,
      session: session,
      dir: dir
    } do
      first =
        conn
        |> authed(session)
        |> post("/admin/banners", %{"place" => "PersonalBlock", "image" => upload()})
        |> json_response(200)

      second =
        conn
        |> authed(session)
        |> post("/admin/banners", %{"place" => "PersonalBlock", "image" => upload()})
        |> json_response(200)

      refute second["image"] == first["image"]

      # Старый файл убран: каталог не копит картинки, на которые никто
      # не ссылается.
      assert length(File.ls!(dir)) == 1

      assert %{items: items} = Banners.list()
      assert Enum.count(items, &(&1.place == "PersonalBlock" and &1.image)) == 1
    end

    test "без картинки у нового места — понятный код, а не 500", %{
      conn: conn,
      session: session
    } do
      conn =
        conn
        |> authed(session)
        |> post("/admin/banners", %{"place" => "OfcLobbyTop", "helper" => "текст"})

      assert %{"code" => "banner_image_required"} = json_response(conn, 422)
    end

    test "у существующего баннера можно поменять только тексты", %{
      conn: conn,
      session: session
    } do
      created =
        conn
        |> authed(session)
        |> post("/admin/banners", %{"place" => "OfcLobbyTop", "image" => upload()})
        |> json_response(200)

      updated =
        conn
        |> authed(session)
        |> post("/admin/banners", %{"place" => "OfcLobbyTop", "helper" => "Китайский покер"})
        |> json_response(200)

      assert updated["image"] == created["image"]
      assert updated["helper"] == "Китайский покер"
    end

    test "не картинка отвергается по содержимому, а не по расширению", %{
      conn: conn,
      session: session
    } do
      conn =
        conn
        |> authed(session)
        |> post("/admin/banners", %{
          "place" => "OfcLobbyTop",
          "image" => upload("<?php echo 1; ?>", "promo.png")
        })

      assert %{"code" => "unsupported_image_type"} = json_response(conn, 422)
    end

    test "неизвестное место не заводит новое", %{conn: conn, session: session} do
      conn =
        conn
        |> authed(session)
        |> post("/admin/banners", %{"place" => "SomewhereElse", "image" => upload()})

      assert %{"code" => "invalid_place"} = json_response(conn, 422)
    end

    test "без токена панели не пускает", %{conn: conn} do
      conn = post(conn, "/admin/banners", %{"place" => "PersonalBlock"})
      assert json_response(conn, 401)
    end
  end

  describe "GET /admin/banners" do
    test "отдаёт все места, включая пустые", %{conn: conn, session: session} do
      conn
      |> authed(session)
      |> post("/admin/banners", %{"place" => "OnRunApplication", "image" => upload()})
      |> json_response(200)

      body =
        conn
        |> authed(session)
        |> get("/admin/banners")
        |> json_response(200)

      assert body["places"] == BlockPoker.Banners.places()
      assert length(body["items"]) == length(body["places"])

      filled = Enum.find(body["items"], &(&1["place"] == "OnRunApplication"))
      assert filled["image"]
      assert Enum.any?(body["items"], &is_nil(&1["image"]))
    end
  end

  describe "GET /api/banners/:place" do
    test "отдаёт баннер без токена: его спрашивают до логина", %{
      conn: conn,
      session: session
    } do
      conn
      |> authed(session)
      |> post("/admin/banners", %{
        "place" => "OnRunApplication",
        "helper" => "Добро пожаловать",
        "image" => upload()
      })
      |> json_response(200)

      body =
        build_conn()
        |> get("/api/banners/OnRunApplication")
        |> json_response(200)

      assert %{"place" => "OnRunApplication", "helper" => "Добро пожаловать", "image" => image} =
               body

      assert String.starts_with?(image, "https://cdn.example/banners/")

      # Имя файла на диске наружу не уходит — снаружи существует только URL.
      refute Map.has_key?(body, "image_file")
    end

    test "пустое место — 404", %{conn: conn} do
      assert %{"code" => "not_found"} =
               conn |> get("/api/banners/TournamentsLobbyTop") |> json_response(404)
    end

    test "неизвестное место — тоже 404, а не отдельный код", %{conn: conn} do
      assert %{"code" => "not_found"} =
               conn |> get("/api/banners/Whatever") |> json_response(404)
    end
  end

  describe "DELETE /admin/banners/:place" do
    test "снимает баннер и убирает его картинку", %{conn: conn, session: session, dir: dir} do
      conn
      |> authed(session)
      |> post("/admin/banners", %{"place" => "SitAndGoLobbyTop", "image" => upload()})
      |> json_response(200)

      assert conn
             |> authed(session)
             |> delete("/admin/banners/SitAndGoLobbyTop")
             |> response(204)

      assert File.ls!(dir) == []
      assert {:error, :not_found} = Banners.get("SitAndGoLobbyTop")
    end

    test "пустое место удалить нельзя", %{conn: conn, session: session} do
      assert %{"code" => "not_found"} =
               conn
               |> authed(session)
               |> delete("/admin/banners/SitAndGoLobbyTop")
               |> json_response(404)
    end
  end
end
