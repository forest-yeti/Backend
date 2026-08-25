defmodule Api.Admin.ClientReleaseControllerTest do
  @moduledoc """
  Уровень 4: загрузка сборки по HTTP насквозь — multipart, ядро, JSON.
  """

  use Api.ConnCase, async: false

  import BlockPoker.AccountsFixtures
  import BlockPoker.AdminFixtures

  alias BlockPoker.ClientReleases
  alias BlockPoker.ClientReleases.Feed

  setup do
    dir = Path.join(System.tmp_dir!(), "release_http_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    previous = Application.get_env(:block_poker, :client_release, [])

    Application.put_env(:block_poker, :client_release,
      current: "0.0.0",
      minimum: "0.0.0",
      feed_url: "https://updates.example/client",
      dir: dir
    )

    Feed.reset()

    on_exit(fn ->
      Application.put_env(:block_poker, :client_release, previous)
      Feed.reset()
      File.rm_rf(dir)
    end)

    Map.merge(admin_with_ctx(), %{dir: dir})
  end

  defp authed(conn, session),
    do: put_req_header(conn, "authorization", "Bearer " <> session.access)

  defp upload_plug(name \\ "BlockPoker-Setup.exe", contents \\ "инсталлятор") do
    path = Path.join(System.tmp_dir!(), "http_upload_#{System.unique_integer([:positive])}.bin")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)

    %Plug.Upload{path: path, filename: name, content_type: "application/octet-stream"}
  end

  describe "POST /admin/client-releases" do
    test "принимает сборку и отдаёт её карточку", %{conn: conn, session: session} do
      conn =
        conn
        |> authed(session)
        |> post("/admin/client-releases", %{"version" => "1.0.1", "file" => upload_plug()})

      assert %{"version" => "1.0.1", "published_at" => nil, "sha512" => sha512} =
               json_response(conn, 201)

      assert sha512 == Base.encode64(:crypto.hash(:sha512, "инсталлятор"))
    end

    test "без файла — понятный код, а не 500", %{conn: conn, session: session} do
      conn =
        conn
        |> authed(session)
        |> post("/admin/client-releases", %{"version" => "1.0.1"})

      assert %{"code" => "release_file_required"} = json_response(conn, 422)
    end

    test "версия не semver — отказ", %{conn: conn, session: session} do
      conn =
        conn
        |> authed(session)
        |> post("/admin/client-releases", %{"version" => "новая", "file" => upload_plug()})

      assert %{"code" => "invalid_version"} = json_response(conn, 422)
    end

    test "игрок не грузит сборки", %{conn: conn} do
      player = user_fixture()
      token = BlockPoker.Accounts.Tokens.issue_socket_token(player)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> post("/admin/client-releases", %{"version" => "1.0.1", "file" => upload_plug()})

      assert json_response(conn, 401)
    end
  end

  describe "публикация и удаление" do
    setup %{conn: conn, session: session} do
      created =
        conn
        |> authed(session)
        |> post("/admin/client-releases", %{"version" => "1.0.1", "file" => upload_plug()})
        |> json_response(201)

      %{release: created}
    end

    test "публикация делает сборку актуальной", %{conn: conn, session: session, release: release} do
      conn =
        conn
        |> authed(session)
        |> post("/admin/client-releases/#{release["id"]}/publish")

      assert %{"published_at" => published_at} = json_response(conn, 200)
      assert published_at
      assert ClientReleases.current() == "1.0.1"
    end

    test "черновик удаляется", %{conn: conn, session: session, release: release} do
      conn = conn |> authed(session) |> delete("/admin/client-releases/#{release["id"]}")

      assert response(conn, 204)
      assert %{items: []} = ClientReleases.list()
    end

    test "опубликованную удалить нельзя", %{conn: conn, session: session, release: release} do
      conn |> authed(session) |> post("/admin/client-releases/#{release["id"]}/publish")

      conn = conn |> authed(session) |> delete("/admin/client-releases/#{release["id"]}")

      assert %{"code" => "release_published"} = json_response(conn, 409)
    end
  end

  describe "GET /admin/client-releases" do
    test "список отдаёт загруженное", %{conn: conn, session: session} do
      conn
      |> authed(session)
      |> post("/admin/client-releases", %{"version" => "1.0.1", "file" => upload_plug()})

      conn = conn |> authed(session) |> get("/admin/client-releases")

      assert %{
               "items" => [%{"version" => "1.0.1", "file_present" => true}],
               "current" => "0.0.0",
               "minimum" => "0.0.0"
             } = json_response(conn, 200)
    end
  end
end
