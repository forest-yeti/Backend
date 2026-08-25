defmodule Api.Admin.AuthJSON do
  @moduledoc """
  Сериализация админской сессии.

  Наружу уходят только публичные поля: ни `password_hash`, ни `token_hash`
  здесь нет и быть не может — это проверяется тестом на сыром теле ответа
  (§11 задачи 8). Сырой refresh-токен отдаётся ровно один раз, в ответе на
  логин и продление: в БД его нет, восстановить его неоткуда.
  """

  alias BlockPoker.Admin.AdminSession

  def session(%{session: session}) do
    %{
      access: session.access,
      refresh: session.refresh,
      expires_in: session.expires_in,
      admin: admin(session.admin),
      session: session_row(session.session, session.session.id)
    }
  end

  def me(%{admin: admin, sessions: sessions, session_id: session_id, observer: observer}) do
    %{
      admin: Map.take(admin, [:id, :name, :email, :role, :status, :avatar, :wallets]),
      sessions: Enum.map(sessions, &session_row(&1, session_id)),
      # Выключенное наблюдение — не ошибка, а состояние: панель по этому
      # флагу прячет вкладку «Стол», а не показывает её и падает на join.
      observer_enabled: observer
    }
  end

  def ok(%{ok: true}), do: %{ok: true}

  defp admin(user) do
    %{id: user.id, name: user.name, email: user.email, avatar: user.avatar, role: user.role}
  end

  defp session_row(%AdminSession{} = session, current_id) do
    %{
      id: session.id,
      ip: session.ip,
      user_agent: session.user_agent,
      expires_at: session.expires_at,
      last_seen_at: session.last_seen_at,
      inserted_at: session.inserted_at,
      current: session.id == current_id
    }
  end
end
