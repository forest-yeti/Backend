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
          | :seat_taken
          | :already_seated
          | :invalid_seat
          | :invalid_buy_in
          | :no_seats_available
          | :not_seated
          | :hand_in_progress
          | :room_closing
          | :zero_stack
          | :reservation_lost
          | :not_your_turn
          | :illegal_action
          | :stale_action
          | :no_hand
          | :hand_finished
          | :chat_too_long
          | :chat_rate_limited
          | :wallet_not_found
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
    seat_taken: {409, "Место уже занято"},
    already_seated: {409, "Вы уже сидите за этим столом"},
    invalid_seat: {422, "Такого места за столом нет"},
    invalid_buy_in: {422, "Сумма бай-ина вне допустимых границ"},
    no_seats_available: {409, "Свободных мест нет"},
    not_seated: {409, "Вы не сидите за этим столом"},
    hand_in_progress: {409, "Действие недоступно во время раздачи"},
    room_closing: {409, "Комната закрывается"},
    zero_stack: {409, "Нулевой стек: сначала докупитесь"},
    reservation_lost: {409, "Резерв места истёк, попробуйте снова"},
    not_your_turn: {409, "Сейчас не ваш ход"},
    illegal_action: {422, "Такое действие сейчас недопустимо"},
    stale_action: {409, "Состояние стола изменилось, повторите действие"},
    no_hand: {409, "Раздача не идёт"},
    hand_finished: {409, "Раздача уже закончилась"},
    chat_too_long: {422, "Сообщение слишком длинное"},
    chat_rate_limited: {429, "Слишком часто: подождите немного"},
    wallet_not_found: {404, "Кошелёк не найден"},
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
