defmodule Api.Admin.AuditController do
  @moduledoc """
  Журнал действий администратора: чтение с курсорной пагинацией и
  фильтрами.

  Только чтение. Записывают журнал сами операции, и записывают в своей
  транзакции — отдельной ручки «записать в журнал» нет и быть не должно.
  """

  use Api, :controller

  alias Api.Admin.AdminParams
  alias BlockPoker.Admin

  action_fallback Api.FallbackController

  def index(conn, params) do
    with {:ok, opts} <- AdminParams.audit(params),
         {:ok, page} <- Admin.audit(conn.assigns.admin_ctx, opts) do
      render(conn, :index, page: page)
    end
  end
end
