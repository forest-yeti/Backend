defmodule BlockPoker.Admin.People do
  @moduledoc """
  Люди глазами панели: список, карточка, бан и разбан.

  Список — курсорный, как история (§5 задачи 8): курсор непрозрачен для
  клиента и собирается из поля сортировки и `id`. Ключ сортировки входит
  в курсор целиком, поэтому смена сортировки начинает страницу заново, а
  не сдвигает её по чужому ключу.

  Балансы берутся из `user_wallets` — денормализованного кэша. Сверка с
  журналом (`verify: true`) считается отдельно и по запросу: это тот самый
  инвариант, который §11 CLAUDE.md требует проверять, и панель делает его
  видимым, а не проверяет на каждой странице.
  """

  import Ecto.Query

  alias BlockPoker.Accounts.User
  alias BlockPoker.Admin.{AdminAudit, Audit, Context}
  alias BlockPoker.Repo
  alias BlockPoker.Tables
  alias BlockPoker.Wallet
  alias BlockPoker.Wallet.UserWallet
  alias Ecto.Multi

  @default_limit 50
  @max_limit 100
  @sorts [:registered_at, :name, :balance]

  @main_amount "COALESCE((SELECT w.amount FROM user_wallets w WHERE w.user_id = ? AND w.type = 'main'), 0)"

  @spec sorts() :: [atom()]
  def sorts, do: @sorts

  @doc """
  Страница списка. `params` — уже разобранная транспортом форма:
  `:cursor`, `:limit`, `:q`, `:status`, `:role`, `:sort`, `:verify`.
  """
  @spec list(map()) :: %{entries: [map()], cursor: term() | nil}
  def list(params) do
    limit = params |> Map.get(:limit) |> normalize_limit()
    sort = Map.get(params, :sort) || :registered_at

    users =
      base_query()
      |> search(params[:q])
      |> filter(:status, params[:status])
      |> filter(:role, params[:role])
      |> sort_by(sort)
      |> seek(sort, params[:cursor])
      |> limit(^(limit + 1))
      |> Repo.all()

    {rows, rest} = Enum.split(users, limit)
    ids = Enum.map(rows, & &1.id)
    wallets = wallets_of(ids)
    seats = Tables.seats_of(ids)
    verify? = params[:verify] == true
    sums = if verify?, do: ledger_sums(wallets), else: %{}

    %{
      entries: Enum.map(rows, &row(&1, wallets, seats, sums, verify?)),
      cursor: cursor_of(rows, rest, sort)
    }
  end

  @doc """
  Карточка: балансы, где сидит прямо сейчас и история банов.

  История банов читается из `admin_audit`, а не хранится отдельным полем:
  «когда и за что» — это и есть журнал, и второе хранилище того же факта
  разошлось бы с ним на первой же ошибке.
  """
  @spec user_card(Ecto.UUID.t()) :: {:ok, map()} | {:error, :not_found}
  def user_card(user_id) do
    with {:ok, user} <- fetch_user(user_id) do
      wallets = wallets_of([user.id])
      sums = ledger_sums(wallets)

      {:ok,
       user
       |> row(wallets, Tables.seats_of([user.id]), sums, true)
       |> Map.put(:bans, ban_history(user.id))}
    end
  end

  @doc "Выписка по кошелькам игрока — страницами, свежие записи первыми."
  @spec ledger(Ecto.UUID.t(), map()) ::
          {:ok, %{entries: [map()], cursor: term() | nil}} | {:error, :not_found}
  def ledger(user_id, params) do
    with {:ok, user} <- fetch_user(user_id) do
      limit = params |> Map.get(:limit) |> normalize_limit()

      rows =
        Wallet.list_user_entries(user.id,
          currency: params[:currency],
          before_seq: params[:cursor],
          limit: limit + 1
        )

      {entries, rest} = Enum.split(rows, limit)

      cursor =
        case {rest, List.last(entries)} do
          {[], _last} -> nil
          {_more, last} -> last.seq
        end

      {:ok, %{entries: entries, cursor: cursor}}
    end
  end

  @doc """
  Бан и разбан. Статус и запись журнала меняются одной транзакцией: не
  записалось — не произошло (§8 задачи 8).
  """
  @spec ban(Context.t(), Ecto.UUID.t(), String.t()) :: {:ok, User.t()} | {:error, atom()}
  def ban(ctx, user_id, reason), do: set_status(ctx, user_id, :blocked, :ban_user, reason)

  @spec unban(Context.t(), Ecto.UUID.t(), String.t()) :: {:ok, User.t()} | {:error, atom()}
  def unban(ctx, user_id, reason), do: set_status(ctx, user_id, :active, :unban_user, reason)

  @doc "Балансы обоих кошельков игрока: `%{main: ..., play_money: ...}`."
  @spec balances(Ecto.UUID.t()) :: %{main: integer(), play_money: integer()}
  def balances(user_id) do
    user_id |> List.wrap() |> wallets_of() |> Map.get(user_id, []) |> balance_map()
  end

  defp set_status(%Context{} = ctx, user_id, status, action, reason) do
    with {:ok, user} <- fetch_user(user_id) do
      Multi.new()
      |> Multi.update(:user, Ecto.Changeset.change(user, status: status))
      |> Audit.step(:audit, ctx, %{
        action: action,
        subject_type: :user,
        subject_id: user.id,
        reason: reason,
        meta: %{before: user.status, after: status}
      })
      |> Repo.transaction()
      |> case do
        {:ok, %{user: updated}} ->
          {:ok, updated}

        # Пустая причина роняет весь `Multi`: статус не меняется, журнал
        # не пишется, и ошибка возвращается кодом, а не текстом.
        {:error, :audit, _changeset, _changes} ->
          {:error, :admin_reason_required}

        {:error, _step, _reason, _changes} ->
          {:error, :validation_failed}
      end
    end
  end

  defp fetch_user(user_id) do
    case Ecto.UUID.cast(user_id) do
      {:ok, uuid} -> user_or_error(Repo.get(User, uuid))
      :error -> {:error, :not_found}
    end
  end

  defp user_or_error(nil), do: {:error, :not_found}
  defp user_or_error(user), do: {:ok, user}

  defp base_query do
    # Касса рума в списке людей не показывается: это кошелёк, а не игрок,
    # и учётки под ним нет — есть строка, заведённая миграцией.
    from(u in User, where: u.id != ^BlockPoker.Wallet.house_user_id())
  end

  defp search(query, nil), do: query
  defp search(query, ""), do: query

  defp search(query, q) when is_binary(q) do
    like = "%#{String.replace(q, ["%", "_"], "")}%"

    where(query, [u], like(u.name, ^like) or like(u.email, ^like))
  end

  defp filter(query, _field, nil), do: query
  defp filter(query, field, value), do: where(query, [u], field(u, ^field) == ^value)

  defp sort_by(query, :name), do: order_by(query, [u], asc: u.name, asc: u.id)

  # Баланс `main` подзапросом, а не join'ом: join по кошелькам размножил бы
  # строку пользователя на число его кошельков, и `limit` считал бы не людей.
  defp sort_by(query, :balance) do
    order_by(query, [u], desc: fragment(@main_amount, u.id), desc: u.id)
  end

  defp sort_by(query, _registered_at), do: order_by(query, [u], desc: u.inserted_at, desc: u.id)

  defp seek(query, _sort, nil), do: query

  defp seek(query, :name, {value, id}) do
    where(query, [u], u.name > ^value or (u.name == ^value and u.id > ^id))
  end

  defp seek(query, :balance, {value, id}) do
    where(
      query,
      [u],
      fragment(@main_amount, u.id) < ^value or
        (fragment(@main_amount, u.id) == ^value and u.id < ^id)
    )
  end

  defp seek(query, _registered_at, {value, id}) do
    where(query, [u], u.inserted_at < ^value or (u.inserted_at == ^value and u.id < ^id))
  end

  defp cursor_of(_rows, [], _sort), do: nil
  defp cursor_of([], _rest, _sort), do: nil

  defp cursor_of(rows, _rest, sort) do
    last = List.last(rows)

    case sort do
      :name -> {last.name, last.id}
      :balance -> {balances(last.id).main, last.id}
      _registered_at -> {last.inserted_at, last.id}
    end
  end

  defp normalize_limit(nil), do: @default_limit
  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)
  defp normalize_limit(_limit), do: @default_limit

  defp wallets_of([]), do: %{}

  defp wallets_of(user_ids) do
    UserWallet
    |> where([w], w.user_id in ^user_ids)
    |> Repo.all()
    |> Enum.group_by(& &1.user_id)
  end

  defp balance_map(wallets) do
    Enum.reduce(wallets, %{main: 0, play_money: 0}, fn wallet, acc ->
      Map.put(acc, wallet.type, wallet.amount)
    end)
  end

  # Сверка кэша с журналом принадлежит кошельковому контексту: панель её
  # только показывает.
  defp ledger_sums(wallets) do
    wallets |> Map.values() |> List.flatten() |> Enum.map(& &1.id) |> Wallet.ledger_sums()
  end

  defp row(user, wallets, seats, sums, verify?) do
    owned = Map.get(wallets, user.id, [])

    %{
      id: user.id,
      name: user.name,
      email: user.email,
      status: user.status,
      role: user.role,
      avatar: user.avatar,
      flair: user.flair,
      wallets: balance_map(owned),
      seated_at: Map.get(seats, user.id, []),
      registered_at: user.inserted_at
    }
    |> maybe_verify(owned, sums, verify?)
  end

  defp maybe_verify(row, _owned, _sums, false), do: row

  defp maybe_verify(row, owned, sums, true) do
    ledger =
      Enum.reduce(owned, %{main: 0, play_money: 0}, fn wallet, acc ->
        Map.put(acc, wallet.type, Map.get(sums, wallet.id, 0))
      end)

    Map.put(row, :verify, %{ledger: ledger, matches: ledger == row.wallets})
  end

  defp ban_history(user_id) do
    AdminAudit
    |> where([a], a.subject_type == :user and a.subject_id == ^user_id)
    |> where([a], a.action in [:ban_user, :unban_user])
    |> order_by([a], desc: a.inserted_at)
    |> limit(50)
    |> preload(:admin)
    |> Repo.all()
  end
end
