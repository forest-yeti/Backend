defmodule BlockPoker.Tickets do
  @moduledoc """
  Контекст билетов: выдача, погашение, возврат, истечение.

  Билет — вторая форма оплаты входа и вторая форма приза. Турнир, который
  платит билетами, и есть саттелит; отдельной сущности «саттелит» в руме
  нет.

  ## Погашение атомарно, и это не деталь

  Погашение — `UPDATE ... WHERE status = 'active'` с проверкой числа
  затронутых строк. Не «прочитать, проверить, записать»: между чтением и
  записью помещается второй запрос того же игрока, и оба уйдут в разные
  турниры по одному билету. Та же защита, что у ledger, и обеспечивает её
  БД, а не код.

  Поэтому все функции, меняющие билет, работают шагами `Ecto.Multi`:
  регистрация билетом — это билет **и** запись участника одной
  транзакцией, а возврат при отмене турнира — билеты **и** деньги
  остальных вместе. Иначе есть окно, в котором игрок уже не в турнире
  и ещё без билета.
  """

  import Ecto.Query

  alias BlockPoker.Repo
  alias BlockPoker.Tickets.{Ticket, UserTicket}
  alias Ecto.Multi

  require Logger

  @doc "Тип билета по идентификатору."
  @spec get_ticket(Ecto.UUID.t()) :: {:ok, Ticket.t()} | {:error, :not_found}
  def get_ticket(id) do
    case Repo.get(Ticket, id) do
      nil -> {:error, :not_found}
      ticket -> {:ok, ticket}
    end
  end

  @doc """
  Заводит тип билета.

  `face_value` задаётся вызывающим, а не берётся из шаблона автоматически:
  билет обязан помнить цену **на момент создания**, и подставлять её
  здесь значило бы пересчитывать её при каждом вызове.
  """
  @spec create_ticket(map()) :: {:ok, Ticket.t()} | {:error, Ecto.Changeset.t()}
  def create_ticket(attrs) do
    %Ticket{} |> Ticket.changeset(attrs) |> Repo.insert()
  end

  @doc "Активные билеты игрока — то, что он видит в кошельке."
  @spec list_active(Ecto.UUID.t(), DateTime.t()) :: [UserTicket.t()]
  def list_active(user_id, now \\ DateTime.utc_now()) do
    UserTicket
    |> where([t], t.user_id == ^user_id and t.status == :active)
    |> where([t], is_nil(t.expires_at) or t.expires_at > ^now)
    |> preload(:ticket)
    |> order_by([t], asc: t.expires_at, asc: t.inserted_at)
    |> Repo.all()
  end

  @doc """
  Годный билет игрока на этот шаблон, если он есть.

  Возвращает **самый скорый к истечению**: иначе игрок копил бы
  бессрочные, а срочные сгорали бы у него на руках.
  """
  @spec find_for(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) ::
          {:ok, UserTicket.t()} | {:error, :not_found}
  def find_for(user_id, setting_id, now \\ DateTime.utc_now()) do
    UserTicket
    |> join(:inner, [ut], t in assoc(ut, :ticket))
    |> where([ut, t], ut.user_id == ^user_id and ut.status == :active)
    |> where([ut, t], t.tournament_setting_id == ^setting_id)
    |> where([ut], is_nil(ut.expires_at) or ut.expires_at > ^now)
    # `NULL` в MySQL сортируется первым, поэтому бессрочные пришлось бы
    # отсеивать вручную; вместо этого сортируем по признаку срочности,
    # а уже потом по сроку.
    |> order_by([ut], asc: is_nil(ut.expires_at), asc: ut.expires_at)
    |> limit(1)
    |> preload(:ticket)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      user_ticket -> {:ok, user_ticket}
    end
  end

  @doc """
  Выдаёт билет игроку. Приз саттелита приходит сюда же.

  `issued_by` — след происхождения (`"tournament:<id>"`, `"admin"`,
  `"promo"`): без него невозможно разобрать жалобу «откуда это у меня».
  """
  @spec issue(Multi.t(), Multi.name(), map()) :: Multi.t()
  def issue(multi, name, attrs) do
    Multi.insert(multi, name, UserTicket.changeset(%UserTicket{}, attrs))
  end

  @doc """
  Погашает билет в турнир — шаг транзакции регистрации.

  Строка билета блокируется (`SELECT ... FOR UPDATE`), проверяется
  статус, и только потом идёт `UPDATE`. Тот же приём, что и у кошелька,
  и по той же причине: «прочитать, проверить, записать» без блокировки
  допускает гонку двух одновременных регистраций одним билетом, каждая
  из которых по отдельности проходит проверку.

  Блокировка, а не условный `UPDATE`, выбрана ради второго правила —
  «один игрок не гасит два билета в один турнир». Его стережёт уникальный
  индекс, а нарушение индекса Ecto умеет превращать в ошибку changeset'а
  только на `Repo.update`: `update_all` отдал бы наружу сырую ошибку
  драйвера, и канал упал бы вместо отказа с понятным кодом.
  """
  @spec redeem(Multi.t(), Multi.name(), UserTicket.t(), Ecto.UUID.t()) :: Multi.t()
  def redeem(multi, name, %UserTicket{} = user_ticket, tournament_id) do
    Multi.run(multi, name, fn repo, _changes ->
      with {:ok, locked} <- lock_active(repo, user_ticket.id) do
        locked
        |> UserTicket.redeem_changeset(tournament_id)
        |> repo.update()
        |> case do
          {:ok, redeemed} -> {:ok, redeemed}
          # Индекс сказал, что билет в этот турнир у игрока уже есть.
          # Это не сбой, а факт: второй билет ему тут не нужен.
          {:error, _changeset} -> {:error, :already_registered}
        end
      end
    end)
  end

  defp lock_active(repo, id) do
    query = from t in UserTicket, where: t.id == ^id, lock: "FOR UPDATE"

    case repo.one(query) do
      %UserTicket{status: :active} = user_ticket -> {:ok, user_ticket}
      %UserTicket{} -> {:error, :ticket_unavailable}
      nil -> {:error, :ticket_unavailable}
    end
  end

  @doc """
  Возвращает билеты, погашенные в турнир, — шаг транзакции отмены.

  Возврат обязан идти в той же транзакции, что и денежные возвраты
  остальным. `used_in_tournament_id` обнуляется вместе со статусом:
  иначе уникальный индекс «один билет на турнир» не пустил бы игрока
  в следующий запуск того же шаблона.
  """
  @spec refund_all(Multi.t(), Multi.name(), Ecto.UUID.t()) :: Multi.t()
  def refund_all(multi, name, tournament_id) do
    Multi.update_all(
      multi,
      name,
      from(t in UserTicket,
        where: t.used_in_tournament_id == ^tournament_id and t.status == :used
      ),
      set: [status: :active, used_in_tournament_id: nil]
    )
  end

  @doc """
  Гасит просроченные билеты. Тело Oban-джобы.

  Истёкший билет в регистрацию не пускают и без этого (`find_for/3`
  фильтрует по сроку); джоба нужна, чтобы игрок видел в кошельке правду,
  а не «активный» купон, которым нельзя воспользоваться.
  """
  @spec expire_due(DateTime.t()) :: {:ok, non_neg_integer()}
  def expire_due(now \\ DateTime.utc_now()) do
    query =
      from t in UserTicket,
        where: t.status == :active and not is_nil(t.expires_at) and t.expires_at <= ^now

    {count, _returned} = Repo.update_all(query, set: [status: :expired])

    {:ok, count}
  end

  @doc """
  Сколько активных билетов пускает в этот шаблон.

  Нужна ровно для одного: предупредить оператора при выключении шаблона.
  Выключенный шаблон не поднимает новых запусков, а значит билет на него
  перестаёт работать и в итоге сгорит. Автокомпенсации деньгами нет —
  рум не выплачивает номинал за то, что передумал проводить турнир, — но
  и сделать это молча движок не даёт.
  """
  @spec count_active_for_setting(Ecto.UUID.t()) :: non_neg_integer()
  def count_active_for_setting(setting_id) do
    UserTicket
    |> join(:inner, [ut], t in assoc(ut, :ticket))
    |> where([ut, t], t.tournament_setting_id == ^setting_id and ut.status == :active)
    |> Repo.aggregate(:count)
  end

  @doc """
  Предупреждает в лог о живых билетах на выключаемый шаблон.

  Оператор увидит, скольких людей затрагивает решение, и сможет погасить
  их вручную до того, как выключит.
  """
  @spec warn_on_disable(Ecto.UUID.t(), String.t()) :: :ok
  def warn_on_disable(setting_id, name) do
    case count_active_for_setting(setting_id) do
      0 ->
        :ok

      count ->
        Logger.warning(
          "шаблон «#{name}» (#{setting_id}) выключен, но на него есть #{count} активных билетов: " <>
            "новых запусков не будет, билеты сгорят по expires_at"
        )
    end
  end
end
