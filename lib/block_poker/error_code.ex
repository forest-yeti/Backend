defmodule BlockPoker.ErrorCode do
  @moduledoc """
  Единый список кодов ошибок для обоих транспортов (§3, §5 CLAUDE.md).

  Наружу уходит код, а не свободный текст: клиент ветвится по коду, человек
  читает `message`. Транспорту остаётся только смапить код в ответ.
  """

  @type t ::
          :validation_failed
          | :invalid_credentials
          | :user_blocked
          | :not_found
          | :token_invalid
          | :token_expired
          | :token_reused
          | :rate_limited
          | :unsupported_protocol_version
          | :insufficient_funds
          | :internal_error

  @codes %{
    validation_failed: {422, "Данные не прошли валидацию"},
    invalid_credentials: {401, "Неверный email или пароль"},
    user_blocked: {403, "Учётная запись заблокирована"},
    not_found: {404, "Не найдено"},
    token_invalid: {401, "Токен недействителен"},
    token_expired: {401, "Токен истёк"},
    token_reused: {401, "Повторное использование отозванного токена"},
    rate_limited: {429, "Слишком много запросов, попробуйте позже"},
    unsupported_protocol_version: {426, "Версия протокола не поддерживается"},
    insufficient_funds: {422, "Недостаточно средств"},
    internal_error: {500, "Внутренняя ошибка"}
  }

  @spec codes() :: [t()]
  def codes, do: Map.keys(@codes)

  @spec valid?(atom()) :: boolean()
  def valid?(code), do: Map.has_key?(@codes, code)

  @doc "HTTP-статус, соответствующий коду."
  @spec http_status(t()) :: pos_integer()
  def http_status(code), do: @codes |> fetch!(code) |> elem(0)

  @doc "Человекочитаемое сообщение для клиента."
  @spec message(t()) :: String.t()
  def message(code), do: @codes |> fetch!(code) |> elem(1)

  defp fetch!(codes, code) do
    case Map.fetch(codes, code) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "неизвестный код ошибки: #{inspect(code)}"
    end
  end
end
