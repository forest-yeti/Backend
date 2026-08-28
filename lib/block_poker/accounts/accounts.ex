defmodule BlockPoker.Accounts do
  @moduledoc """
  Контекст учётных записей: регистрация, аутентификация, сессии.

  Наружу отдаёт либо структуры домена, либо коды из `BlockPoker.ErrorCode` —
  свободного текста в ошибках нет (§3 CLAUDE.md).
  """

  import Ecto.Query, only: [from: 2]

  alias BlockPoker.Accounts.{Tokens, User}
  alias BlockPoker.Repo
  alias BlockPoker.Wallet
  alias Ecto.Multi

  @type session :: %{
          user: User.t(),
          token: String.t(),
          refresh_token: String.t(),
          expires_in: pos_integer(),
          wallets: [Wallet.UserWallet.t()]
        }

  @doc """
  Регистрация: пользователь и оба кошелька создаются одной транзакцией —
  либо всё, либо ничего. Дефолтные суммы принадлежат кошельковому контексту.
  """
  @spec register(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def register(attrs) do
    Multi.new()
    |> Multi.insert(:user, User.registration_changeset(%User{}, attrs))
    |> Wallet.create_default_wallets(:user)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _changes} -> {:error, changeset}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  @spec authenticate(String.t(), String.t()) ::
          {:ok, User.t()} | {:error, :invalid_credentials | :user_blocked}
  def authenticate(email, password) when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: User.normalize_email(email))

    cond do
      is_nil(user) ->
        # Пустая проверка выравнивает время ответа: иначе по задержке
        # перебирается список существующих email.
        Argon2.no_user_verify()
        {:error, :invalid_credentials}

      not Argon2.verify_pass(password, user.password_hash) ->
        {:error, :invalid_credentials}

      user.status == :blocked ->
        {:error, :user_blocked}

      true ->
        {:ok, user}
    end
  end

  def authenticate(_email, _password) do
    Argon2.no_user_verify()
    {:error, :invalid_credentials}
  end

  @spec get_user(Ecto.UUID.t()) :: {:ok, User.t()} | {:error, :not_found}
  def get_user(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> id_to_result(Repo.get(User, uuid))
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Снимки профилей пачкой: ник, аватар, флейр и роль по списку id.

  Существует ради турнирной рассадки. Сажать три сотни человек по одному
  `get_user/1` — три сотни round-trip'ов на старте, ровно та причина, по
  которой рядом стоит `mark_playing/1` на весь список сразу.

  Отсутствующие id просто не попадают в результат: место без ника — это
  ник «Игрок» на клиенте, а не отказ в посадке.
  """
  @spec profiles([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => BlockPoker.Tables.RoomState.profile()}
  def profiles([]), do: %{}

  def profiles(user_ids) do
    ids = for id <- user_ids, {:ok, uuid} = Ecto.UUID.cast(id), do: uuid

    from(u in User, where: u.id in ^ids, select: {u.id, u.name, u.avatar, u.flair, u.role})
    |> Repo.all()
    |> Map.new(fn {id, name, avatar, flair, role} ->
      {id, %{name: name, avatar: avatar, flair: flair, role: role}}
    end)
  end

  @doc """
  Поиск учётки по нику или email — для команд обслуживания, где UUID под
  рукой нет. Ник регистрозависим, email нормализуется, как при регистрации.
  """
  @spec find_user(String.t()) :: {:ok, User.t()} | {:error, :not_found}
  def find_user(identifier) when is_binary(identifier) do
    normalized = User.normalize_email(identifier)

    query =
      from(u in User,
        where: u.name == ^identifier or u.email == ^normalized,
        limit: 1
      )

    id_to_result(Repo.one(query))
  end

  @doc """
  Смена роли. Роль наружу не отдаётся и через транспорт не меняется:
  назначает её только команда `mix user.role`.
  """
  @spec set_role(User.t(), atom() | String.t()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def set_role(%User{} = user, role) do
    user |> User.role_changeset(role) |> Repo.update()
  end

  @doc """
  Смена косметики. Как и роль, назначается только командой (`mix user.flair`):
  через сокет игрок себе метку не поставит — иначе выделение перестало бы
  что-либо значить.
  """
  @spec set_flair(User.t(), String.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def set_flair(%User{} = user, flair) do
    user |> User.flair_changeset(flair) |> Repo.update()
  end

  @doc """
  Смена аватара. Единственная косметика, которую игрок ставит себе сам,
  поэтому путь у неё транспортный, а не через mix-задачу: клиент присылает
  метку строкой, сервер сверяет её со списком известных и сохраняет.

  Аватар за столом — снимок профиля на момент посадки, так что новая метка
  доедет до соседей со следующей посадки.
  """
  @spec set_avatar(Ecto.UUID.t(), String.t()) ::
          {:ok, User.t()} | {:error, :not_found | :validation_failed}
  def set_avatar(user_id, avatar) do
    with {:ok, user} <- get_user(user_id),
         {:ok, updated} <- user |> User.avatar_changeset(avatar) |> Repo.update() do
      {:ok, updated}
    else
      {:error, %Ecto.Changeset{}} -> {:error, :validation_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Регистрация + сразу выданная пара токенов."
  @spec register_session(map()) :: {:ok, session()} | {:error, Ecto.Changeset.t()}
  def register_session(attrs) do
    with {:ok, user} <- register(attrs), do: start_session(user)
  end

  @doc "Вход по email и паролю."
  @spec login(String.t(), String.t()) ::
          {:ok, session()} | {:error, :invalid_credentials | :user_blocked}
  def login(email, password) do
    with {:ok, user} <- authenticate(email, password), do: start_session(user)
  end

  @doc "Продление сессии по refresh-токену с ротацией самого токена."
  @spec refresh_session(String.t()) ::
          {:ok, session()}
          | {:error, :token_invalid | :token_expired | :token_reused | :user_blocked}
  def refresh_session(refresh_token) do
    with {:ok, %{user: user, refresh_token: raw}} <- Tokens.refresh(refresh_token),
         :ok <- ensure_active(user) do
      {:ok, build_session(user, raw)}
    end
  end

  @doc "Проверка socket-токена при открытии соединения."
  @spec verify_socket_token(String.t()) ::
          {:ok, User.t()} | {:error, :token_invalid | :token_expired | :user_blocked}
  def verify_socket_token(token) do
    with {:ok, user_id} <- Tokens.verify_socket_token(token),
         {:ok, user} <- socket_user(user_id),
         :ok <- ensure_active(user) do
      {:ok, user}
    end
  end

  @spec start_session(User.t()) :: {:ok, session()}
  def start_session(%User{} = user) do
    {:ok, refresh_token} = Tokens.issue_refresh_token(user)
    {:ok, build_session(user, refresh_token)}
  end

  defp build_session(%User{} = user, refresh_token) do
    %{
      user: user,
      token: Tokens.issue_socket_token(user),
      refresh_token: refresh_token,
      expires_in: Tokens.socket_token_ttl(),
      wallets: Wallet.list_wallets(user.id)
    }
  end

  defp socket_user(user_id) do
    case get_user(user_id) do
      {:ok, user} -> {:ok, user}
      {:error, :not_found} -> {:error, :token_invalid}
    end
  end

  defp ensure_active(%User{status: :active}), do: :ok
  defp ensure_active(%User{}), do: {:error, :user_blocked}

  defp id_to_result(nil), do: {:error, :not_found}
  defp id_to_result(user), do: {:ok, user}
end
