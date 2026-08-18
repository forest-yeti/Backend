defmodule Socket.Protocol.Message do
  @moduledoc """
  Разбор и валидация **формы** входящего payload — и ничего больше.

  Граница проходит так: «поле есть, тип верный, число в границах `int`» —
  здесь; «хватает ли денег, свободно ли место, в границах ли бай-ин» —
  в контексте (§3 CLAUDE.md). Поэтому в этом модуле нет ни одного числа
  из правил игры.
  """

  alias BlockPoker.ErrorCode

  @spec fetch_id(map(), String.t()) :: {:ok, Ecto.UUID.t()} | {:error, :validation_failed}
  def fetch_id(payload, key) do
    with value when is_binary(value) <- Map.get(payload, key),
         {:ok, uuid} <- Ecto.UUID.cast(value) do
      {:ok, uuid}
    else
      _other -> {:error, :validation_failed}
    end
  end

  @doc "Суммы — целые в минимальных единицах. Float в деньгах запрещён (§5 CLAUDE.md)."
  @spec fetch_amount(map(), String.t()) :: {:ok, pos_integer()} | {:error, :validation_failed}
  def fetch_amount(payload, key) do
    case Map.get(payload, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, :validation_failed}
    end
  end

  @spec fetch_seat(map(), String.t()) :: {:ok, pos_integer()} | {:error, :validation_failed}
  def fetch_seat(payload, key) do
    case Map.get(payload, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, :validation_failed}
    end
  end

  @doc """
  Игровое действие из payload. Сумма рейза — «до какой величины», а не
  «сколько добавить»: так её понимает и стол, и правило мин-рейза.
  """
  @spec fetch_action(map()) :: {:ok, term()} | {:error, atom()}
  def fetch_action(%{"type" => type} = payload) do
    case type do
      "fold" -> {:ok, :fold}
      "check" -> {:ok, :check}
      "call" -> {:ok, :call}
      "all_in" -> {:ok, :all_in}
      raise_kind when raise_kind in ["bet", "raise"] -> fetch_raise(payload)
      _other -> {:error, :validation_failed}
    end
  end

  def fetch_action(_payload), do: {:error, :validation_failed}

  defp fetch_raise(payload) do
    case fetch_amount(payload, "amount") do
      {:ok, amount} -> {:ok, {:raise, amount}}
      error -> error
    end
  end

  @doc "Счётчик стола, который видел клиент. Без него действие не проверяется."
  @spec action_seq(map()) :: non_neg_integer() | nil
  def action_seq(%{"action_seq" => seq}) when is_integer(seq) and seq >= 0, do: seq
  def action_seq(_payload), do: nil

  @doc """
  Намерение при входе в игру. Канал его только передаёт: решает контекст,
  и он же вправе это намерение переопределить (§6 задачи 3).
  """
  @spec entry(map()) :: :wait_bb | :post
  def entry(%{"entry" => "post"}), do: :post
  def entry(_payload), do: :wait_bb

  @doc """
  Ответ на измерение задержки.

  Ядро тут ни при чём: замер — свойство соединения, а не игры, поэтому
  вся «логика» сводится к тому, чтобы вернуть клиенту его же метку и
  добавить своё время. Круговую задержку считает клиент: только у него
  есть оба конца замера, и только его часы участвуют в обеих отметках.

  Серверное время отдаётся отдельным полем — по нему клиент оценивает
  расхождение часов. Игровые сроки на нём считать нельзя: дедлайны ходов
  приходят остатком в миллисекундах и в чужих часах не нуждаются.
  """
  @spec pong(map()) :: map()
  def pong(payload) do
    %{client_time: Map.get(payload, "t"), server_time: System.system_time(:millisecond)}
  end

  @doc "Результат вызова контекста → ответ канала."
  @spec reply(term(), Phoenix.Socket.t()) :: {:reply, term(), Phoenix.Socket.t()}
  def reply(:ok, socket), do: {:reply, :ok, socket}
  def reply({:ok, result}, socket) when is_map(result), do: {:reply, {:ok, result}, socket}
  def reply({:error, code}, socket), do: error_reply(code, socket)

  @spec error_reply(atom(), Phoenix.Socket.t()) :: {:reply, {:error, map()}, Phoenix.Socket.t()}
  def error_reply(code, socket) do
    {:reply, {:error, error(code)}, socket}
  end

  @doc """
  Код ошибки → payload для клиента. Неизвестный контексту код наружу не
  уходит: клиент ветвится по закрытому списку, а не по случайному атому.
  """
  @spec error(atom()) :: %{code: String.t(), message: String.t()}
  def error(code) do
    code = if ErrorCode.valid?(code), do: code, else: :internal_error
    %{code: Atom.to_string(code), message: ErrorCode.message(code)}
  end
end
