defmodule BlockPoker.Accounts.Tokens do
  @moduledoc """
  Выдача и проверка токенов.

  * **Socket-токен** — stateless, `Phoenix.Token`, TTL 1 час, в БД не хранится.
    Им авторизуется само WebSocket-соединение.
  * **Refresh-токен** — 32 случайных байта, клиенту в Base64URL, в БД — SHA-256.
    Обновление ротирует токен: старый отзывается, выдаётся новый. Повторное
    предъявление отозванного токена трактуется как компрометация — отзывается
    вся цепочка токенов пользователя.
  """

  import Ecto.Query

  alias BlockPoker.Accounts.{RefreshToken, User}
  alias BlockPoker.Repo
  alias Ecto.Multi

  @socket_salt "user socket"
  @socket_token_ttl 3_600
  @refresh_token_ttl_days 30
  @refresh_token_bytes 32

  @spec socket_token_ttl() :: pos_integer()
  def socket_token_ttl, do: @socket_token_ttl

  @doc "Short-lived токен для открытия сокета."
  @spec issue_socket_token(User.t()) :: String.t()
  def issue_socket_token(%User{id: user_id}) do
    Phoenix.Token.sign(token_context(), @socket_salt, user_id)
  end

  @spec verify_socket_token(String.t()) ::
          {:ok, Ecto.UUID.t()} | {:error, :token_expired | :token_invalid}
  def verify_socket_token(token) when is_binary(token) do
    case Phoenix.Token.verify(token_context(), @socket_salt, token, max_age: @socket_token_ttl) do
      {:ok, user_id} -> {:ok, user_id}
      {:error, :expired} -> {:error, :token_expired}
      {:error, _reason} -> {:error, :token_invalid}
    end
  end

  def verify_socket_token(_token), do: {:error, :token_invalid}

  @doc "Создаёт refresh-токен. Возвращает открытую часть — её видит только клиент."
  @spec issue_refresh_token(User.t()) :: {:ok, String.t()} | {:error, Ecto.Changeset.t()}
  def issue_refresh_token(%User{} = user) do
    {raw, record} = build_refresh_token(user)

    with {:ok, _record} <- Repo.insert(record), do: {:ok, raw}
  end

  @doc """
  Ротация refresh-токена: в одной транзакции старый отзывается, выдаётся новый.
  """
  @spec refresh(String.t()) ::
          {:ok, %{user: User.t(), refresh_token: String.t()}}
          | {:error, :token_invalid | :token_expired | :token_reused | :user_blocked}
  def refresh(raw_token) when is_binary(raw_token) do
    with {:ok, token} <- fetch_refresh_token(raw_token),
         :ok <- ensure_usable(token) do
      rotate(token)
    end
  end

  def refresh(_raw_token), do: {:error, :token_invalid}

  @doc "Отзывает все действующие токены пользователя."
  @spec revoke_all(Ecto.UUID.t()) :: {non_neg_integer(), nil}
  def revoke_all(user_id) do
    RefreshToken
    |> where([t], t.user_id == ^user_id and is_nil(t.revoked_at))
    |> Repo.update_all(set: [revoked_at: DateTime.utc_now(), updated_at: DateTime.utc_now()])
  end

  @doc "Удаляет просроченные токены. Вызывается периодической задачей Oban."
  @spec delete_expired(DateTime.t()) :: {non_neg_integer(), nil}
  def delete_expired(now \\ DateTime.utc_now()) do
    RefreshToken
    |> where([t], t.expires_at < ^now)
    |> Repo.delete_all()
  end

  defp rotate(%RefreshToken{} = token) do
    user = Repo.get!(User, token.user_id)
    {raw, record} = build_refresh_token(user)

    Multi.new()
    |> Multi.update(:revoked, Ecto.Changeset.change(token, revoked_at: DateTime.utc_now()))
    |> Multi.insert(:issued, record)
    |> Repo.transaction()
    |> case do
      {:ok, _changes} -> {:ok, %{user: user, refresh_token: raw}}
      {:error, _step, _reason, _changes} -> {:error, :token_invalid}
    end
  end

  defp fetch_refresh_token(raw_token) do
    case Repo.get_by(RefreshToken, token_hash: hash(raw_token)) do
      nil -> {:error, :token_invalid}
      token -> {:ok, token}
    end
  end

  defp ensure_usable(%RefreshToken{revoked_at: revoked_at, user_id: user_id})
       when not is_nil(revoked_at) do
    # Отозванный токен предъявлен повторно — считаем цепочку скомпрометированной.
    revoke_all(user_id)
    {:error, :token_reused}
  end

  defp ensure_usable(%RefreshToken{expires_at: expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
      do: :ok,
      else: {:error, :token_expired}
  end

  defp build_refresh_token(%User{} = user) do
    raw = @refresh_token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    record = %RefreshToken{
      user_id: user.id,
      token_hash: hash(raw),
      expires_at: DateTime.add(DateTime.utc_now(), @refresh_token_ttl_days, :day)
    }

    {raw, record}
  end

  defp hash(raw_token), do: :crypto.hash(:sha256, raw_token)

  defp token_context, do: Application.fetch_env!(:block_poker, :token_context)
end
