defmodule Api.Admin.UserController do
  @moduledoc """
  Люди: список, карточка, выписка, бан и деньги.

  Каждое действие — разбор параметров, сборка `%Admin.Context{}` из
  `conn.assigns` и **один** вызов контекста. Ни балансов, ни сумм по
  журналу, ни решения «админ ли это» здесь нет (§9 задачи 8).
  """

  use Api, :controller

  alias Api.Admin.AdminParams
  alias BlockPoker.Admin

  action_fallback Api.FallbackController

  def index(conn, params) do
    with {:ok, opts} <- AdminParams.users(params),
         {:ok, page} <- Admin.list_users(ctx(conn), opts) do
      render(conn, :index, page: page)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, user} <- Admin.user_card(ctx(conn), id) do
      render(conn, :show, user: user)
    end
  end

  def ledger(conn, %{"id" => id} = params) do
    with {:ok, opts} <- AdminParams.ledger(params),
         {:ok, page} <- Admin.ledger(ctx(conn), id, opts) do
      render(conn, :ledger, page: page)
    end
  end

  def ban(conn, %{"id" => id} = params) do
    with {:ok, user} <- Admin.ban(ctx(conn), id, params["reason"]) do
      render(conn, :status, user: user)
    end
  end

  def unban(conn, %{"id" => id} = params) do
    with {:ok, user} <- Admin.unban(ctx(conn), id, params["reason"]) do
      render(conn, :status, user: user)
    end
  end

  def credit(conn, %{"id" => id} = params) do
    with {:ok, body} <- AdminParams.money(params),
         {:ok, result} <-
           Admin.credit(
             ctx(conn),
             id,
             body.currency,
             body.amount,
             params["reason"],
             body.idempotency_key
           ) do
      render(conn, :money, result: result)
    end
  end

  def take(conn, %{"id" => id} = params) do
    with {:ok, body} <- AdminParams.money(params),
         {:ok, result} <-
           Admin.take_to_admin(
             ctx(conn),
             id,
             body.currency,
             body.amount,
             params["reason"],
             body.idempotency_key
           ) do
      render(conn, :money, result: result)
    end
  end

  defp ctx(conn), do: conn.assigns.admin_ctx
end
