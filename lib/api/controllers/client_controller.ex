defmodule Api.ClientController do
  @moduledoc """
  Версия клиентского приложения и адрес фида обновлений.

  Почему HTTP, а не сообщение канала (§3 CLAUDE.md): клиент спрашивает это
  **до** того, как соединение существует. Устаревшая сборка не проходит
  handshake, а сборка без токена до него и не доходит — но обновиться должна
  и та, и другая. Тот же случай, что и `POST /api/auth/login`.

  Ручка публичная и не требует токена по той же причине.
  """

  use Api, :controller

  alias BlockPoker.ClientRelease

  def show(conn, _params) do
    json(conn, ClientRelease.info())
  end
end
