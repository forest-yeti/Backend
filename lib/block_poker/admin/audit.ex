defmodule BlockPoker.Admin.Audit do
  @moduledoc """
  Запись журнала действий. Вызывается **изнутри** операций, а не рядом с
  ними: запись идёт той же транзакцией, что и сама операция, — не
  записалось, значит не произошло (§8 задачи 8).

  Наружу отдаются два входа: шаг `Ecto.Multi` для операций, у которых
  транзакция уже есть, и самостоятельная запись для действий, которым
  менять нечего (вход, открытие наблюдения).
  """

  import Ecto.Query

  alias BlockPoker.Admin.{AdminAudit, Context}
  alias BlockPoker.Repo
  alias Ecto.Multi

  @doc """
  Шаг записи аудита внутри чужой транзакции.

  `attrs` — карта или функция от накопленных `changes`: денежные операции
  кладут в `meta` состояние до и после, а оно известно только по ходу
  `Multi`.
  """
  @spec step(Multi.t(), atom(), Context.t(), map() | (map() -> map())) :: Multi.t()
  def step(multi, name, %Context{} = ctx, attrs) do
    Multi.insert(multi, name, fn changes ->
      attrs = if is_function(attrs, 1), do: attrs.(changes), else: attrs
      changeset(ctx, attrs)
    end)
  end

  @doc "Самостоятельная запись: действие, которое ничего не меняет в БД."
  @spec write(Context.t(), map()) :: {:ok, AdminAudit.t()} | {:error, Ecto.Changeset.t()}
  def write(%Context{} = ctx, attrs), do: ctx |> changeset(attrs) |> Repo.insert()

  @doc """
  Неудачный вход: сессии ещё нет, поэтому запись идёт без неё.

  Пишется только тогда, когда учётка нашлась: `admin_id` — внешний ключ,
  и записать попытку по несуществующему email просто некуда.
  """
  @spec login_failed(Ecto.UUID.t(), String.t(), map()) :: :ok
  def login_failed(admin_id, ip, meta) do
    Repo.insert(
      changeset(%Context{admin_id: admin_id, session_id: nil, ip: ip}, %{
        action: :login_failed,
        subject_type: :user,
        subject_id: admin_id,
        meta: meta
      })
    )

    :ok
  end

  @doc "Страница журнала, свежие записи первыми."
  @spec list(map()) :: %{entries: [AdminAudit.t()], cursor: String.t() | nil}
  def list(params) do
    limit = params[:limit] || 50

    AdminAudit
    |> filter_by(:admin_id, params[:admin_id])
    |> filter_by(:action, params[:action])
    |> filter_by(:subject_id, params[:subject_id])
    |> filter_by(:subject_type, params[:subject_type])
    |> apply_cursor(params[:cursor])
    |> order_by([a], desc: a.inserted_at, desc: a.id)
    |> limit(^(limit + 1))
    |> preload(:admin)
    |> Repo.all()
    |> page(limit)
  end

  defp filter_by(query, _field, nil), do: query
  defp filter_by(query, field, value), do: where(query, [a], field(a, ^field) == ^value)

  defp apply_cursor(query, nil), do: query

  defp apply_cursor(query, {at, id}) do
    where(query, [a], a.inserted_at < ^at or (a.inserted_at == ^at and a.id < ^id))
  end

  # Лишняя строка запрашивается ради ответа на вопрос «есть ли следующая
  # страница»: без неё последняя страница неотличима от полной.
  defp page(rows, limit) do
    {entries, rest} = Enum.split(rows, limit)

    cursor =
      case {rest, List.last(entries)} do
        {[], _last} -> nil
        {_more, last} -> {last.inserted_at, last.id}
      end

    %{entries: entries, cursor: cursor}
  end

  defp changeset(%Context{} = ctx, attrs) do
    AdminAudit.changeset(
      %AdminAudit{},
      attrs
      |> Map.put(:admin_id, ctx.admin_id)
      |> Map.put(:session_id, ctx.session_id)
      |> Map.put(:ip, ctx.ip)
    )
  end
end
