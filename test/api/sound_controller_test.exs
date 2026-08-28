defmodule Api.Admin.SoundControllerTest do
  @moduledoc """
  Уровень 4: звуки по HTTP насквозь — multipart из панели, ядро, событие
  в сокет.

  Файлы здесь пишутся на диск по-настоящему: формат проверяется по
  содержимому, и проверять это на моке файловой системы значило бы
  проверять мок (§11 CLAUDE.md).
  """

  use Api.ConnCase, async: false

  import BlockPoker.AdminFixtures
  import BlockPoker.TablesHelpers

  alias BlockPoker.Admin
  alias BlockPoker.Tables.TableServer

  # Минимальный настоящий MP3: тегированный файл начинается с `ID3`.
  @mp3 <<"ID3", 3, 0, 0, 0::size(64)>>

  setup do
    dir = Path.join(System.tmp_dir!(), "sounds_http_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    previous = Application.get_env(:block_poker, :sounds, [])
    Application.put_env(:block_poker, :sounds, dir: dir, base_url: "https://cdn.example/sounds")

    on_exit(fn ->
      Application.put_env(:block_poker, :sounds, previous)
      File.rm_rf(dir)
    end)

    Map.merge(admin_with_ctx(), %{dir: dir})
  end

  defp authed(conn, session),
    do: put_req_header(conn, "authorization", "Bearer " <> session.access)

  defp upload(contents \\ @mp3, name \\ "gong.mp3") do
    path = Path.join(System.tmp_dir!(), "sound_upload_#{System.unique_integer([:positive])}")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)

    %Plug.Upload{path: path, filename: name, content_type: "audio/mpeg"}
  end

  defp create!(conn, session, title \\ "Гонг") do
    conn
    |> authed(session)
    |> post("/admin/sounds", %{"title" => title, "file" => upload()})
    |> json_response(201)
  end

  describe "POST /admin/sounds" do
    test "кладёт звук в библиотеку и отдаёт готовый адрес", %{conn: conn, session: session} do
      assert %{"id" => _id, "title" => "Гонг", "url" => url, "format" => "mp3"} =
               create!(conn, session)

      assert String.starts_with?(url, "https://cdn.example/sounds/")
      assert String.ends_with?(url, ".mp3")
    end

    test "файл не той природы отвергается по содержимому, а не по имени", %{
      conn: conn,
      session: session
    } do
      assert %{"code" => "unsupported_audio_type"} =
               conn
               |> authed(session)
               |> post("/admin/sounds", %{
                 "title" => "Подделка",
                 "file" => upload("вовсе не звук", "fake.mp3")
               })
               |> json_response(422)
    end

    test "без названия — понятный код, а не 500", %{conn: conn, session: session} do
      assert %{"code" => "sound_title_required"} =
               conn
               |> authed(session)
               |> post("/admin/sounds", %{"title" => "  ", "file" => upload()})
               |> json_response(422)
    end

    test "без файла — понятный код", %{conn: conn, session: session} do
      assert %{"code" => "sound_file_required"} =
               conn
               |> authed(session)
               |> post("/admin/sounds", %{"title" => "Пустышка"})
               |> json_response(422)
    end
  end

  describe "GET /admin/sounds и DELETE /admin/sounds/:id" do
    test "список отдаёт загруженное, удаление убирает и запись, и файл", %{
      conn: conn,
      session: session,
      dir: dir
    } do
      %{"id" => id, "url" => url} = create!(conn, session)

      assert %{"items" => [%{"id" => ^id}]} =
               conn |> authed(session) |> get("/admin/sounds") |> json_response(200)

      file = Path.basename(url)
      assert File.exists?(Path.join(dir, file))

      assert conn |> authed(session) |> delete("/admin/sounds/#{id}") |> response(204)

      assert %{"items" => []} =
               conn |> authed(session) |> get("/admin/sounds") |> json_response(200)

      refute File.exists?(Path.join(dir, file))
    end
  end

  describe "воспроизведение" do
    test "в комнату уходит событием стола", %{conn: conn, session: session} do
      ensure_tables!()
      %{room_id: room_id} = start_room!()
      :ok = Phoenix.PubSub.subscribe(BlockPoker.PubSub, TableServer.topic(room_id))

      %{"id" => sound_id, "url" => url} = create!(conn, session)

      assert %{"id" => play_id, "url" => ^url} =
               conn
               |> authed(session)
               |> post("/admin/games/cash/#{room_id}/sound", %{"sound_id" => sound_id})
               |> json_response(200)

      assert_receive {:table_event, "sound", %{id: ^play_id, url: ^url, title: "Гонг"}}
    end

    test "несуществующая комната — понятный код, а не молчание", %{conn: conn, session: session} do
      %{"id" => sound_id} = create!(conn, session)

      assert %{"code" => "admin_room_not_found"} =
               conn
               |> authed(session)
               |> post("/admin/games/cash/#{Ecto.UUID.generate()}/sound", %{
                 "sound_id" => sound_id
               })
               |> json_response(404)
    end

    test "всему залу уходит общим топиком и пишется в журнал", %{
      conn: conn,
      session: session,
      ctx: ctx
    } do
      :ok = Phoenix.PubSub.subscribe(BlockPoker.PubSub, BlockPoker.Sounds.everyone_topic())

      %{"id" => sound_id} = create!(conn, session)

      assert %{"id" => play_id} =
               conn
               |> authed(session)
               |> post("/admin/sounds/#{sound_id}/play", %{})
               |> json_response(200)

      assert_receive {:sound, %{id: ^play_id, title: "Гонг"}}

      {:ok, %{entries: entries}} = Admin.audit(ctx, %{})
      entry = Enum.find(entries, &(&1.action == :sound_play))
      assert entry.subject_id == sound_id
      assert entry.meta["target"] == "everyone"
    end

    test "неизвестный звук — 404", %{conn: conn, session: session} do
      assert %{"code" => "not_found"} =
               conn
               |> authed(session)
               |> post("/admin/sounds/#{Ecto.UUID.generate()}/play", %{})
               |> json_response(404)
    end
  end

  test "без токена панели не пускает", %{conn: conn} do
    assert conn |> get("/admin/sounds") |> json_response(401)
  end
end
