defmodule BlockPoker.History do
  @moduledoc """
  Контекст истории раздач и статистики игрока.

  Публичный API у контекста один на два очень разных потребителя.

  **Пишут процессы игры** — `TableServer` по концу раздачи и
  `TournamentServer` по вылету игрока. Обе дороги асинхронны и обе идут
  через `History.Writer`: ни стол, ни турнир не ждут БД ни микросекунды.
  Отказ MySQL останавливает историю, но не игру.

  **Читает HTTP** — единственное чтение проекта, вынесенное из сокета.
  История не real-time: сервер ничего не пушит, состояние не меняется под
  игроком, ответ идемпотентен и кэшируется, а объём страницы не должен
  делить пропускную способность с игровым сокетом.

  Инвариант «в `api/*` нет бизнес-логики» этим не ослабляется: контроллер
  достаёт `user_id` из `conn.assigns`, парсит параметры страницы, зовёт
  одну функцию отсюда и рендерит.
  """

  alias BlockPoker.History.{Queries, Report, Store, Writer}

  @doc """
  Отдать законченную раздачу на запись. Возврат немедленный: стол про
  раздачу забывает и не обязан знать, записалась ли она.
  """
  @spec persist_async(Report.t()) :: :ok
  def persist_async(%Report{} = report), do: Writer.persist(report)

  @doc "Отдать итог турнирного входа на запись. Идемпотентно по `entry_id`."
  @spec persist_tournament_result_async(map()) :: :ok
  def persist_tournament_result_async(snapshot), do: Writer.persist_tournament_result(snapshot)

  @doc """
  Закрылось окно добровольного показа: игроки, открывшиеся сами, получают
  видимость `voluntary`.
  """
  @spec reveal_cards_async(Ecto.UUID.t(), [Ecto.UUID.t()]) :: :ok
  def reveal_cards_async(hand_id, user_ids), do: Writer.reveal_cards(hand_id, user_ids)

  @doc "Синхронная запись собранной раздачи. Зовёт её только Oban-воркер."
  @spec write(map()) :: {:ok, :written | :already} | {:error, term()}
  defdelegate write(rows), to: Store

  @doc "Синхронная запись итога турнирного входа. Зовёт её только Oban-воркер."
  @spec write_tournament_result(map()) :: {:ok, :written | :already} | {:error, term()}
  defdelegate write_tournament_result(attrs), to: Store

  @doc "Пометить добровольно открытые карты. Зовёт её только Oban-воркер."
  @spec mark_voluntary(Ecto.UUID.t(), [Ecto.UUID.t()]) :: {:ok, non_neg_integer()}
  defdelegate mark_voluntary(hand_id, user_ids), to: Store

  @doc "Страница своей истории раздач."
  @spec list_hands(Ecto.UUID.t(), map()) :: %{items: [map()], cursor: Queries.cursor()}
  defdelegate list_hands(user_id, opts \\ %{}), to: Queries

  @doc "Одна раздача целиком. Чужая — `{:error, :not_found}`."
  @spec get_hand(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, :not_found}
  defdelegate get_hand(user_id, hand_id), to: Queries

  @doc "Сводка показателей за период, разрезом по режиму."
  @spec stats(Ecto.UUID.t(), map()) :: %{atom() => map()}
  defdelegate stats(user_id, opts \\ %{}), to: Queries

  @doc "Точки графика банкролла."
  @spec graph(Ecto.UUID.t(), map()) :: [map()]
  defdelegate graph(user_id, opts \\ %{}), to: Queries

  @doc "Страница сыгранных турниров."
  @spec list_tournaments(Ecto.UUID.t(), map()) :: %{items: [struct()], cursor: Queries.cursor()}
  defdelegate list_tournaments(user_id, opts \\ %{}), to: Queries

  @doc "Один турнир: входы игрока и его раздачи."
  @spec get_tournament(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, :not_found}
  defdelegate get_tournament(user_id, tournament_id), to: Queries

  @doc "Турнирная сводка: ROI, ITM, средняя финишная позиция."
  @spec tournament_summary(Ecto.UUID.t(), map()) :: map()
  defdelegate tournament_summary(user_id, opts \\ %{}), to: Queries

  @doc """
  Сколько дней живут раздачи. Конфиг, а не константа в коде джоба: срок
  почти наверняка будет меняться.
  """
  @spec retention_days() :: pos_integer()
  def retention_days, do: Application.get_env(:block_poker, :history_retention_days, 90)
end
