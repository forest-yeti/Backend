defmodule Api.Admin.AuditJSON do
  @moduledoc """
  Рендер журнала действий.

  Наружу уходит запись как она есть, плюс имя администратора: `admin_id`
  в интерфейсе не читается, а второй запрос за ним панель делать не
  должна.
  """

  alias Api.Admin.AdminParams

  def index(%{page: page}) do
    %{items: Enum.map(page.entries, &row/1), cursor: AdminParams.encode_cursor(page.cursor)}
  end

  defp row(entry) do
    %{
      id: entry.id,
      action: entry.action,
      subject_type: entry.subject_type,
      subject_id: entry.subject_id,
      amount: entry.amount,
      currency: entry.currency,
      reason: entry.reason,
      meta: entry.meta,
      ip: entry.ip,
      at: entry.inserted_at,
      admin: %{id: entry.admin_id, name: entry.admin && entry.admin.name}
    }
  end
end
