defmodule Api.Router do
  use Api, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", Api do
    pipe_through :api

    get "/health", HealthController, :show
  end

  scope "/api", Api do
    pipe_through :api

    # post "/auth/register", AuthController, :register
    # post "/auth/login", AuthController, :login
    # post "/auth/refresh", AuthController, :refresh
  end
end
