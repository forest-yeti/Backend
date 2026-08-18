defmodule Api.Plugs.RateLimit do
  @moduledoc """
  Ограничение частоты запросов по IP.

      plug Api.Plugs.RateLimit, scope: :login, limit: 10, window_ms: :timer.minutes(5)

  Транспортная мера защиты, доменных правил не содержит.
  """

  import Plug.Conn

  alias BlockPoker.ErrorCode

  @behaviour Plug

  @impl true
  def init(opts) do
    %{
      scope: Keyword.fetch!(opts, :scope),
      limit: Keyword.fetch!(opts, :limit),
      window_ms: Keyword.fetch!(opts, :window_ms)
    }
  end

  @impl true
  def call(conn, %{scope: scope, limit: limit, window_ms: window_ms}) do
    case Api.RateLimiter.hit({scope, client_ip(conn)}, limit, window_ms) do
      :ok ->
        conn

      {:error, :rate_limited} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          ErrorCode.http_status(:rate_limited),
          Jason.encode!(%{code: "rate_limited", message: ErrorCode.message(:rate_limited)})
        )
        |> halt()
    end
  end

  defp client_ip(%Plug.Conn{remote_ip: remote_ip}), do: :inet.ntoa(remote_ip) |> to_string()
end
