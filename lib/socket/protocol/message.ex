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
  Намерение при входе в игру. Канал его только передаёт: решает контекст,
  и он же вправе это намерение переопределить (§6 задачи 3).
  """
  @spec entry(map()) :: :wait_bb | :post
  def entry(%{"entry" => "post"}), do: :post
  def entry(_payload), do: :wait_bb

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
