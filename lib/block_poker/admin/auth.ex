defmodule BlockPoker.Admin.Auth do
  @moduledoc """
  Вход в панель: те же email и пароль, что в игровом клиенте, но
  **отдельный токен** и отдельная сессия.

  Соль admin-токена отличается от игровой, поэтому игровой токен физически
  не проходит верификацию здесь, а админский — в `UserSocket` (§5 задачи 8).
  Утёкший из игрового клиента токен доступа в панель не даёт.

  `access` — stateless `Phoenix.Token`, TTL 15 минут, и в нём лежит
  **идентификатор сессии**, а не пользователя: строка сессии проверяется
  при каждом запросе, и её отзыв закрывает доступ мгновенно.
  `refresh` — 32 случайных байта, в БД хэш, TTL 12 часов, с ротацией.
  """

  import Ecto.Query

  alias BlockPoker.Accounts
  alias BlockPoker.Accounts.User
  alias BlockPoker.Admin.{AdminSession, Audit, Context}
  alias BlockPoker.Repo
  alias Ecto.Multi

  @access_salt "admin access"
  @access_ttl 900
  @refresh_ttl_hours 12
  @refresh_bytes 32

  @type meta :: %{optional(:ip) => String.t(), optional(:user_agent) => String.t()}

  @spec access_ttl() :: pos_integer()
  def access_ttl, do: @access_ttl

  @doc """
  Вход. При `role != :admin`, блокировке и неверном пароле ответ один и
  тот же — `invalid_credentials`: панель не должна быть оракулом «этот
  email админский».
  """
  @spec login(String.t(), String.t(), meta()) ::
          {:ok, map()} | {:error, :invalid_credentials}
  def login(email, password, meta) do
    case Accounts.authenticate(email, password) do
      {:ok, %User{role: :admin, status: :active} = admin} ->
        start_session(admin, meta)

      {:ok, %User{} = user} ->
        # Учётка есть, но входить ей сюда нечем. Попытка попадает в
        # журнал: это ровно тот сигнал, ради которого журнал заводится.
        Audit.login_failed(user.id, ip(meta), %{reason: "not_admin"})
        {:error, :invalid_credentials}

      {:error, _reason} ->
        {:error, :invalid_credentials}
    end
  end

  @doc "Продление пары. Предъявленный refresh отзывается немедленно."
  @spec refresh(String.t(), meta()) ::
          {:ok, map()} | {:error, :token_invalid | :admin_session_expired | :admin_required}
  def refresh(raw_token, meta) when is_binary(raw_token) do
    now = DateTime.utc_now()

    with {:ok, session} <- fetch_by_token(raw_token),
         :ok <- ensure_active(session, now),
         {:ok, admin} <- ensure_admin(session.user_id) do
      {raw, attrs} = build_refresh(admin, meta, now)

      Multi.new()
      |> Multi.update(:revoked, Ecto.Changeset.change(session, revoked_at: now))
      |> Multi.insert(:issued, AdminSession.changeset(%AdminSession{}, attrs))
      |> Repo.transaction()
      |> case do
        {:ok, %{issued: issued}} -> {:ok, issued_pair(admin, issued, raw)}
        {:error, _step, _reason, _changes} -> {:error, :token_invalid}
      end
    end
  end

  def refresh(_raw_token, _meta), do: {:error, :token_invalid}

  @doc "Отзыв сессии. Закрывает и HTTP, и сокет — оба сверяются с этой строкой."
  @spec logout(Ecto.UUID.t()) :: :ok
  def logout(session_id) do
    AdminSession
    |> where([s], s.id == ^session_id and is_nil(s.revoked_at))
    |> Repo.update_all(set: [revoked_at: DateTime.utc_now(), updated_at: DateTime.utc_now()])

    :ok
  end

  @doc """
  Проверка access-токена: подпись, живость сессии и роль.

  Плаг зовёт её и ничего не решает сам — роль проверяется здесь и внутри
  каждой операции `Admin` (§4 задачи 8).
  """
  @spec authorize(String.t()) ::
          {:ok, %{admin: User.t(), session: AdminSession.t()}}
          | {:error, :token_invalid | :token_expired | :admin_session_expired | :admin_required}
  def authorize(token) when is_binary(token) do
    with {:ok, session_id} <- verify_access(token),
         {:ok, session} <- fetch_session(session_id),
         :ok <- ensure_active(session, DateTime.utc_now()),
         {:ok, admin} <- ensure_admin(session.user_id) do
      touch(session)
      {:ok, %{admin: admin, session: session}}
    end
  end

  def authorize(_token), do: {:error, :token_invalid}

  @doc """
  Жива ли сессия прямо сейчас.

  Нужна сокету: access-токен stateless и переживает отзыв сессии до конца
  своего TTL, а держать открытым god-mode отозванному админу нельзя.
  Поэтому соединение перепроверяет строку — при каждом `join` и по
  таймеру (§8 задачи 8).
  """
  @spec session_alive?(Ecto.UUID.t()) :: boolean()
  def session_alive?(nil), do: false

  def session_alive?(session_id) do
    with {:ok, session} <- fetch_session(session_id),
         :ok <- ensure_active(session, DateTime.utc_now()),
         {:ok, _admin} <- ensure_admin(session.user_id) do
      true
    else
      _other -> false
    end
  end

  @doc "Живые сессии админа — их видно в `/admin/auth/me`."
  @spec list_sessions(Ecto.UUID.t()) :: [AdminSession.t()]
  def list_sessions(admin_id) do
    now = DateTime.utc_now()

    AdminSession
    |> where([s], s.user_id == ^admin_id and is_nil(s.revoked_at) and s.expires_at > ^now)
    |> order_by([s], desc: s.last_seen_at)
    |> Repo.all()
  end

  @doc "Есть ли у учётки право работать с панелью. Единственная проверка роли."
  @spec ensure_admin(Ecto.UUID.t()) :: {:ok, User.t()} | {:error, :admin_required}
  def ensure_admin(user_id) do
    case Accounts.get_user(user_id) do
      {:ok, %User{role: :admin, status: :active} = admin} -> {:ok, admin}
      _other -> {:error, :admin_required}
    end
  end

  defp start_session(admin, meta) do
    now = DateTime.utc_now()
    {raw, attrs} = build_refresh(admin, meta, now)

    with {:ok, session} <- Repo.insert(AdminSession.changeset(%AdminSession{}, attrs)) do
      Audit.write(%Context{admin_id: admin.id, session_id: session.id, ip: ip(meta)}, %{
        action: :login,
        subject_type: :user,
        subject_id: admin.id,
        meta: %{user_agent: meta[:user_agent]}
      })

      {:ok, issued_pair(admin, session, raw)}
    end
  end

  defp issued_pair(admin, session, raw_refresh) do
    %{
      access: Phoenix.Token.sign(token_context(), @access_salt, session.id),
      refresh: raw_refresh,
      admin: admin,
      session: session,
      expires_in: @access_ttl
    }
  end

  defp build_refresh(admin, meta, now) do
    raw = @refresh_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    attrs = %{
      user_id: admin.id,
      token_hash: hash(raw),
      ip: ip(meta),
      user_agent: meta[:user_agent],
      expires_at: DateTime.add(now, @refresh_ttl_hours, :hour),
      last_seen_at: now
    }

    {raw, attrs}
  end

  defp verify_access(token) do
    case Phoenix.Token.verify(token_context(), @access_salt, token, max_age: @access_ttl) do
      {:ok, session_id} -> {:ok, session_id}
      {:error, :expired} -> {:error, :token_expired}
      {:error, _reason} -> {:error, :token_invalid}
    end
  end

  defp fetch_session(session_id) do
    case Repo.get(AdminSession, session_id) do
      nil -> {:error, :token_invalid}
      session -> {:ok, session}
    end
  end

  defp fetch_by_token(raw_token) do
    case Repo.get_by(AdminSession, token_hash: hash(raw_token)) do
      nil -> {:error, :token_invalid}
      session -> {:ok, session}
    end
  end

  defp ensure_active(session, now) do
    if AdminSession.active?(session, now), do: :ok, else: {:error, :admin_session_expired}
  end

  # Отметка живости — не проверка: она обновляет строку и ничего не решает.
  defp touch(session) do
    Repo.update_all(
      from(s in AdminSession, where: s.id == ^session.id),
      set: [last_seen_at: DateTime.utc_now(), updated_at: DateTime.utc_now()]
    )
  end

  defp hash(raw), do: :sha256 |> :crypto.hash(raw) |> Base.encode16(case: :lower)

  defp ip(meta), do: meta[:ip] || "0.0.0.0"

  defp token_context, do: Application.fetch_env!(:block_poker, :token_context)
end
