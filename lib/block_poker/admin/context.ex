defmodule BlockPoker.Admin.Context do
  @moduledoc """
  Кто делает действие: админ, его сессия и адрес.

  Собирается транспортом из `conn.assigns` / `socket.assigns` и передаётся
  единственным аргументом. Транспорт отвечает на вопрос «кто это»,
  контекст — на вопрос «можно ли ему» (§4 задачи 8): роль проверяется
  внутри каждой публичной функции `Admin`, а не в плаге.
  """

  @enforce_keys [:admin_id, :session_id, :ip]
  defstruct [:admin_id, :session_id, :ip]

  @type t :: %__MODULE__{
          admin_id: Ecto.UUID.t(),
          session_id: Ecto.UUID.t() | nil,
          ip: String.t()
        }
end
