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
          | :leave_in_progress
          | :add_chips_in_progress
          | :add_chips_lost
          | :no_queued_add_chips
          | :post_not_available
          | :straddle_unavailable
          | :invalid_straddle
          | :invalid_placement
          | :start_not_available
          | :zero_stack
          | :already_sitting_out
          | :reservation_lost
          | :not_your_turn
          | :illegal_action
          | :stale_action
          | :no_hand
          | :hand_finished
          | :chat_too_long
          | :chat_rate_limited
          | :reaction_rate_limited
          | :rabbit_unavailable
          | :reveal_unavailable
          | :already_shown
          | :run_it_twice_not_offered
          | :not_a_contender
          | :already_answered
          | :wallet_not_found
          | :registration_closed
          | :tournament_started
          | :tournament_cancelled
          | :tournament_full
          | :unregister_too_late
          | :not_registered
          | :already_registered
          | :reentry_not_allowed
          | :rebuy_limit_reached
          | :addon_not_allowed
          | :addon_already_taken
          | :ticket_required
          | :ticket_unavailable
          | :ticket_expired
          | :admin_required
          | :admin_session_expired
          | :admin_reason_required
          | :admin_amount_invalid
          | :admin_insufficient_funds
          | :admin_self_target
          | :admin_room_not_found
          | :admin_observer_disabled
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
    leave_in_progress: {409, "Вы встаёте из-за стола: дождитесь завершения"},
    add_chips_in_progress: {409, "Предыдущая докупка ещё не завершена"},
    add_chips_lost: {409, "Докупка потеряна, повторите"},
    no_queued_add_chips: {409, "Отменять нечего: отложенной докупки нет"},
    post_not_available: {409, "Войти за взнос сейчас нельзя"},
    straddle_unavailable: {409, "Страддл сейчас недоступен"},
    invalid_straddle: {422, "Размер страддла вне допустимых границ"},
    invalid_placement: {422, "Так карты выложить нельзя"},
    start_not_available: {409, "Запустить игру сейчас нельзя"},
    zero_stack: {409, "Нулевой стек: сначала докупитесь"},
    already_sitting_out: {409, "Вы уже в паузе"},
    reservation_lost: {409, "Резерв места истёк, попробуйте снова"},
    not_your_turn: {409, "Сейчас не ваш ход"},
    illegal_action: {422, "Такое действие сейчас недопустимо"},
    stale_action: {409, "Состояние стола изменилось, повторите действие"},
    no_hand: {409, "Раздача не идёт"},
    hand_finished: {409, "Раздача уже закончилась"},
    chat_too_long: {422, "Сообщение слишком длинное"},
    chat_rate_limited: {429, "Слишком часто: подождите немного"},
    reaction_rate_limited: {429, "Реакцию можно отправить раз в минуту"},
    rabbit_unavailable: {409, "Посмотреть карты сейчас нельзя"},
    reveal_unavailable: {409, "Показать карты сейчас нельзя"},
    already_shown: {409, "Эти карты уже открыты"},
    run_it_twice_not_offered: {409, "Сыграть дважды сейчас не предлагают"},
    not_a_contender: {403, "Вы не участвуете в этой раздаче"},
    already_answered: {409, "Вы уже ответили"},
    wallet_not_found: {404, "Кошелёк не найден"},
    registration_closed: {409, "Регистрация закрыта"},
    tournament_started: {409, "Турнир уже начался"},
    tournament_cancelled: {409, "Турнир отменён"},
    tournament_full: {409, "Мест в турнире больше нет"},
    unregister_too_late: {409, "Разрегистрироваться уже нельзя"},
    not_registered: {409, "Вы не зарегистрированы в этом турнире"},
    already_registered: {409, "Вы уже зарегистрированы"},
    reentry_not_allowed: {409, "Повторный вход в этом турнире запрещён"},
    rebuy_limit_reached: {409, "Лимит повторных входов исчерпан"},
    addon_not_allowed: {409, "Аддон сейчас недоступен"},
    addon_already_taken: {409, "Аддон в этом турнире уже взят"},
    ticket_required: {422, "Подходящего билета нет"},
    ticket_unavailable: {409, "Билет уже использован"},
    ticket_expired: {422, "Срок действия билета истёк"},
    # Панель администратора (задача 8). `admin_required` отвечает `403`, а
    # не `404`: сюда доходит только тот, чей токен уже проверен, и прятать
    # от него существование ручки бессмысленно.
    admin_required: {403, "Нужны права администратора"},
    admin_session_expired: {401, "Сессия администратора истекла"},
    admin_reason_required: {422, "Нужно указать причину"},
    admin_amount_invalid: {422, "Некорректная сумма"},
    admin_insufficient_funds: {422, "На кошельке игрока недостаточно средств"},
    admin_self_target: {422, "Себе начислять и списывать нельзя"},
    admin_room_not_found: {404, "Комната не найдена"},
    admin_observer_disabled: {403, "Наблюдение за столами выключено"},
    internal_error: {500, "Внутренняя ошибка"}
  }

  @spec codes() :: [t()]
  def codes, do: Map.keys(@codes)

  @spec valid?(atom()) :: boolean()
  def valid?(code), do: Map.has_key?(@codes, code)

  @doc """
  Код по строке, пришедшей с провода.

  Существует ради того, чтобы разбор не делался через
  `String.to_existing_atom/1`: тот падает, если атом ещё не создан, а создан
  он ровно тогда, когда этот модуль успел загрузиться. Получается ошибка
  разбора ошибки — обработчик отказа роняет сам себя, и происходит это
  тем вероятнее, чем реже путь используется.

  Сравнение идёт со списком известных кодов: неизвестная строка получает
  `:error`, а не исключение.
  """
  @spec fetch(term()) :: {:ok, t()} | :error
  def fetch(code) when is_binary(code) do
    case Enum.find(@codes, fn {known, _value} -> Atom.to_string(known) == code end) do
      {known, _value} -> {:ok, known}
      nil -> :error
    end
  end

  def fetch(code) when is_atom(code) do
    if valid?(code), do: {:ok, code}, else: :error
  end

  def fetch(_code), do: :error

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
