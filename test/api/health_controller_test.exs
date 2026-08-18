defmodule Api.HealthControllerTest do
  use Api.ConnCase, async: true

  test "GET /health отвечает ok", %{conn: conn} do
    conn = get(conn, "/health")
    assert %{"status" => "ok"} = json_response(conn, 200)
  end
end
