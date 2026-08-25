defmodule Api.Admin.UserJSON do
  @moduledoc """
  Рендер людей.

  Строка списка приходит из контекста уже в той форме, в какой её видит
  панель: балансы посчитаны, посадки собраны, сверка с журналом сделана.
  Перекладывать её по полю значило бы завести здесь второе описание того
  же (§9 задачи 8).

  Единственное, что здесь действительно делается, — кодирование курсора
  и явный отбор полей учётки: `password_hash` наружу не уходит ни при
  каких условиях.
  """

  alias Api.Admin.AdminParams

  def index(%{page: page}) do
    %{items: Enum.map(page.entries, &row/1), cursor: AdminParams.encode_cursor(page.cursor)}
  end

  def show(%{user: user}), do: user |> row() |> Map.put(:bans, Enum.map(user.bans, &ban/1))

  def ledger(%{page: page}) do
    %{items: page.entries, cursor: AdminParams.encode_cursor(page.cursor)}
  end

  # Из учётки наружу уходят ровно два поля, и берутся они по имени, а не
  # разбором схемы: `password_hash` лежит в той же структуре, и рендер «всё,
  # кроме» рано или поздно вынес бы его наружу.
  def status(%{user: user}), do: %{id: user.id, status: user.status}

  def money(%{result: result}), do: result

  defp row(user) do
    Map.take(user, [
      :id,
      :name,
      :email,
      :status,
      :role,
      :avatar,
      :flair,
      :wallets,
      :seated_at,
      :registered_at,
      :verify
    ])
  end

  # Запись журнала о бане: кто, когда и почему. Имя админа берётся из
  # предзагруженной учётки — id в интерфейсе не читается.
  defp ban(entry) do
    %{
      action: entry.action,
      reason: entry.reason,
      at: entry.inserted_at,
      admin: %{id: entry.admin_id, name: entry.admin && entry.admin.name}
    }
  end
end
