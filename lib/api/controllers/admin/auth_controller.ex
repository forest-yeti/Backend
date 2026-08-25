defmodule Api.Admin.AuthController do
  @moduledoc """
  Вход в панель: те же email и пароль, что в игровом клиенте, но отдельная
  пара токенов.

  Контроллер не знает ни про соль токена, ни про роли, ни про `Repo`:
  разбирает тело запроса, собирает мету соединения и зовёт одну функцию
  контекста (§9 задачи 8).
  """

  use Api, :controller

  alias BlockPoker.Admin

  action_fallback Api.FallbackController

  def login(conn, %{"email" => email, "password" => password})
      when is_binary(email) and is_binary(password) do
    with {:ok, session} <- Admin.login(email, password, meta(conn)) do
      render(conn, :session, session: session)
    end
  end

  def login(_conn, _params), do: {:error, :validation_failed}

  def refresh(conn, %{"refresh" => refresh}) when is_binary(refresh) do
    with {:ok, session} <- Admin.refresh(refresh, meta(conn)) do
      render(conn, :session, session: session)
    end
  end

  def refresh(_conn, _params), do: {:error, :validation_failed}

  def logout(conn, _params) do
    :ok = Admin.logout(conn.assigns.admin_ctx.session_id)

    render(conn, :ok, ok: true)
  end

  def me(conn, _params) do
    ctx = conn.assigns.admin_ctx

    with {:ok, admin} <- Admin.user_card(ctx, ctx.admin_id),
         {:ok, sessions} <- Admin.sessions(ctx) do
      render(conn, :me,
        admin: admin,
        sessions: sessions,
        session_id: ctx.session_id,
        observer: Admin.observer_enabled?()
      )
    end
  end

  # Адрес и клиент запоминаются в сессии и уходят в журнал: «кто это
  # сделал» без «откуда» отвечает на половину вопроса.
  defp meta(conn) do
    %{ip: Api.Plugs.AdminAuth.client_ip(conn), user_agent: user_agent(conn)}
  end

  defp user_agent(conn) do
    case get_req_header(conn, "user-agent") do
      [value | _rest] -> String.slice(value, 0, 255)
      [] -> nil
    end
  end
end
