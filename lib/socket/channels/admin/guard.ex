defmodule Socket.Channels.Admin.Guard do
  @moduledoc """
  Общее для всех админских каналов: проверка живости сессии.

  Access-токен stateless и переживает отзыв сессии до конца своего TTL,
  поэтому открытое соединение обязано перепроверять строку — при `join`
  и раз в минуту по таймеру (§8 задачи 8). Отозванный админ теряет и
  наблюдение, и списки в ту же минуту, а не через четверть часа.

  Транспортная механика и ничего больше: «жива ли сессия» отвечает
  контекст, здесь только вопрос и закрытие канала.
  """

  alias BlockPoker.Admin
  alias Socket.Protocol.Message

  @check_ms :timer.minutes(1)

  @doc "Проверка при входе. Отзыв закрывает канал раньше, чем он что-то отдаст."
  @spec allow(Phoenix.Socket.t()) :: :ok | {:error, map()}
  def allow(socket) do
    if Admin.session_alive?(socket.assigns.admin_ctx) do
      schedule()
      :ok
    else
      {:error, Message.error(:admin_session_expired)}
    end
  end

  @doc false
  @spec schedule() :: reference()
  def schedule, do: Process.send_after(self(), :check_session, @check_ms)

  @doc false
  @spec recheck(Phoenix.Socket.t()) :: {:noreply, Phoenix.Socket.t()} | {:stop, term(), map()}
  def recheck(socket) do
    if Admin.session_alive?(socket.assigns.admin_ctx) do
      schedule()
      {:noreply, socket}
    else
      # Клиент получает причину, а не молчаливый разрыв: панель по этому
      # коду отправляет админа на экран логина, а не пытается переподключиться.
      Phoenix.Channel.push(socket, "error", Message.error(:admin_session_expired))
      {:stop, :shutdown, socket}
    end
  end
end
