defmodule Api.AuthController do
  @moduledoc """
  Регистрация, вход и продление токена — единственное, что физически нельзя
  сделать по сокету (§3 CLAUDE.md).

  Контроллер не знает ни про хэширование паролей, ни про `Repo`, ни про правила
  валидации: разбирает payload, вызывает одну функцию контекста, рендерит ответ.
  """

  use Api, :controller

  alias BlockPoker.Accounts

  action_fallback Api.FallbackController

  def register(conn, params) do
    with {:ok, session} <- Accounts.register_session(registration_params(params)) do
      conn
      |> put_status(:created)
      |> render(:session, session: session)
    end
  end

  def login(conn, %{"email" => email, "password" => password})
      when is_binary(email) and is_binary(password) do
    with {:ok, session} <- Accounts.login(email, password) do
      render(conn, :session, session: session)
    end
  end

  def login(_conn, _params), do: {:error, :validation_failed}

  def refresh(conn, %{"refresh_token" => refresh_token}) when is_binary(refresh_token) do
    with {:ok, session} <- Accounts.refresh_session(refresh_token) do
      render(conn, :session, session: session)
    end
  end

  def refresh(_conn, _params), do: {:error, :validation_failed}

  defp registration_params(params), do: Map.take(params, ["name", "email", "password"])
end
