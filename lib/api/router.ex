defmodule Api.Router do
  use Api, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Защита перебора: логин и регистрация — 10 попыток за 5 минут на IP,
  # продление токена — 30 (клиент дёргает его штатно, на каждом реконнекте).
  pipeline :auth_rate_limit do
    plug Api.Plugs.RateLimit, scope: :auth, limit: 10, window_ms: 300_000
  end

  pipeline :refresh_rate_limit do
    plug Api.Plugs.RateLimit, scope: :refresh, limit: 30, window_ms: 300_000
  end

  scope "/", Api do
    pipe_through :api

    get "/health", HealthController, :show
  end

  scope "/api", Api do
    pipe_through [:api, :auth_rate_limit]

    post "/auth/register", AuthController, :register
    post "/auth/login", AuthController, :login
  end

  scope "/api", Api do
    pipe_through [:api, :refresh_rate_limit]

    post "/auth/refresh", AuthController, :refresh
  end
end
