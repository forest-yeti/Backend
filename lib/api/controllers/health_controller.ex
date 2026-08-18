defmodule Api.HealthController do
  use Api, :controller

  def show(conn, _params) do
    json(conn, %{status: "ok", version: Application.spec(:block_poker, :vsn) |> to_string()})
  end
end
