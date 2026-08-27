defmodule Api.Admin.AnnouncementControllerTest do
  @moduledoc """
  Уровень 4: объявление по HTTP насквозь — панель, ядро, журнал.
  """

  use Api.ConnCase, async: false

  import BlockPoker.AdminFixtures

  alias BlockPoker.Admin

  setup do
    admin_with_ctx()
  end

  defp authed(conn, session),
    do: put_req_header(conn, "authorization", "Bearer " <> session.access)

  test "отправляет объявление и пишет факт в журнал", %{conn: conn, session: session, ctx: ctx} do
    :ok = Phoenix.PubSub.subscribe(BlockPoker.PubSub, BlockPoker.Announcements.topic())

    body =
      conn
      |> authed(session)
      |> post("/admin/announcements", %{
        "title" => "Технические работы",
        "text" => "Через 15 минут"
      })
      |> json_response(201)

    assert %{"id" => id, "title" => "Технические работы", "text" => "Через 15 минут"} = body
    assert_receive {:announcement, %{id: ^id}}

    {:ok, %{entries: entries}} = Admin.audit(ctx, %{})
    entry = Enum.find(entries, &(&1.action == :announcement))
    assert entry.subject_id == id
    assert entry.meta["text"] == "Через 15 минут"
  end

  test "пустой текст — понятный код, а не 500", %{conn: conn, session: session} do
    assert %{"code" => "announcement_text_required"} =
             conn
             |> authed(session)
             |> post("/admin/announcements", %{"text" => "   "})
             |> json_response(422)
  end

  test "слишком длинный текст отвергается", %{conn: conn, session: session} do
    assert %{"code" => "announcement_too_long"} =
             conn
             |> authed(session)
             |> post("/admin/announcements", %{"text" => String.duplicate("а", 1001)})
             |> json_response(422)
  end

  test "без токена панели не пускает", %{conn: conn} do
    assert conn |> post("/admin/announcements", %{"text" => "привет"}) |> json_response(401)
  end
end
