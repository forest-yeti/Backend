defmodule Api.ClientControllerTest do
  use Api.ConnCase, async: false

  setup do
    previous = Application.get_env(:block_poker, :client_release, [])
    BlockPoker.ClientReleases.Feed.reset()

    Application.put_env(:block_poker, :client_release,
      current: "1.4.2",
      minimum: "1.4.0",
      feed_url: "https://cdn.example/client-updates"
    )

    on_exit(fn ->
      Application.put_env(:block_poker, :client_release, previous)
      BlockPoker.ClientReleases.Feed.reset()
    end)

    :ok
  end

  test "GET /api/client/version отдаёт версии и фид без токена", %{conn: conn} do
    conn = get(conn, "/api/client/version")

    assert %{
             "current" => "1.4.2",
             "minimum" => "1.4.0",
             "feed_url" => "https://cdn.example/client-updates"
           } = json_response(conn, 200)
  end
end
