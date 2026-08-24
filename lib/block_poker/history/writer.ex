defmodule BlockPoker.History.Writer do
  @moduledoc """
  Процесс между столом и Oban.

  Существует ради одной вещи, которую легко потерять при наивной
  реализации: **`Oban.insert/1` — это `Repo.insert`.** Строчка
  `Oban.insert(...)` внутри `finish_hand/2` выглядит как «поставили задачу
  в фон», а фактически берёт коннект из пула синхронно, в вызывающем
  процессе — то есть ставит стол в очередь за коннектом ровно в тот
  момент, когда пул исчерпан пиком нагрузки, и таймеры хода живых игроков
  едут (§11 задачи 6).

  Поэтому связь со столом — `cast`, а не `call`: `GenServer.call` вернул бы
  блокировку чёрным ходом, сделав очередь занятого Writer очередью стола.
  Стол отдаёт сырой отчёт и возвращается к игре; сборка строк, вычисление
  позиций и постановка задачи происходят уже здесь.

  Ошибка постановки задачи не роняет ни Writer, ни стол: раздача теряется,
  игра — нет. Это осознанный размен, зафиксированный в §6 задачи: отказ
  MySQL останавливает историю, но не игру.
  """

  use GenServer

  require Logger

  alias BlockPoker.History.{Build, Report}
  alias BlockPoker.History.Workers.{PersistHand, PersistTournamentResult, RevealCards}

  @doc "Запустить процесс записи. Имя фиксировано: стол шлёт по имени."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Отдать законченную раздачу. Возврат немедленный и всегда `:ok` — стол
  про раздачу забывает и не обязан знать, записалась ли она.
  """
  @spec persist(Report.t(), GenServer.server()) :: :ok
  def persist(%Report{} = report, server \\ __MODULE__) do
    cast(server, {:hand, report})
  end

  @doc """
  Отдать итог турнирного входа. Тот же процесс и та же дорога: вылет
  игрока — это ещё и пересадка, и проверка окончания уровня, и они не
  имеют права стоять в очереди за коннектом.
  """
  @spec persist_tournament_result(map(), GenServer.server()) :: :ok
  def persist_tournament_result(snapshot, server \\ __MODULE__) when is_map(snapshot) do
    cast(server, {:tournament_result, snapshot})
  end

  @doc """
  Закрылось окно добровольного показа: отметить открытые карты.

  Второй, маленький апдейт: показ бывает **после** записи раздачи, а
  запись не имеет права ждать окно — иначе следующая раздача упрётся в
  предыдущую (§4 задачи 6).
  """
  @spec reveal_cards(Ecto.UUID.t(), [Ecto.UUID.t()], GenServer.server()) :: :ok
  def reveal_cards(hand_id, user_ids, server \\ __MODULE__)

  def reveal_cards(_hand_id, [], _server), do: :ok

  def reveal_cards(hand_id, user_ids, server) do
    cast(server, {:reveal, hand_id, user_ids})
  end

  # Процесса может не быть: в тестах он не поднимается вместе с
  # приложением по той же причине, что и лобби, — база там живёт под
  # Sandbox и принадлежит тест-процессу, а Writer пишет из своего.
  # Отсутствие Writer означает «историю не ведём», а не ошибку: игра от
  # неё не зависит ни в одном месте.
  defp cast(server, message) do
    if GenServer.whereis(server), do: GenServer.cast(server, message), else: :ok
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast({:hand, %Report{} = report}, state) do
    enqueue(PersistHand, %{rows: Build.rows(report)}, hand_id: report.hand_id)
    {:noreply, state}
  end

  def handle_cast({:tournament_result, snapshot}, state) do
    enqueue(PersistTournamentResult, %{result: snapshot}, entry_id: snapshot[:entry_id])
    {:noreply, state}
  end

  def handle_cast({:reveal, hand_id, user_ids}, state) do
    enqueue(RevealCards, %{hand_id: hand_id, user_ids: user_ids}, hand_id: hand_id)
    {:noreply, state}
  end

  # Полезная нагрузка едет в аргументе задачи **термом**, а не разложенным
  # по ключам JSON. Причина техническая и одна: в строках лежат атомы
  # (`Ecto.Enum`), `Date` и `DateTime`, а JSON их не различает — обратно
  # они вернулись бы строками, и каждую пришлось бы приводить руками,
  # заведя второй, необязательный источник ошибок между сборкой и записью.
  defp enqueue(worker, payload, meta) do
    payload
    |> pack()
    |> worker.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("history: enqueue failed #{inspect(meta)} #{inspect(reason)}")
    end
  rescue
    # Недоступная база не имеет права уронить Writer: раздача потеряется,
    # игра — нет.
    error -> Logger.error("history: enqueue crashed #{inspect(meta)} #{inspect(error)}")
  end

  @doc "Упаковка полезной нагрузки задачи. Публична ради воркеров."
  @spec pack(term()) :: map()
  def pack(payload) do
    %{"payload" => payload |> :erlang.term_to_binary() |> Base.encode64()}
  end

  @doc "Обратная распаковка. `:safe` — термы свои, чужих здесь не бывает."
  @spec unpack(map()) :: term()
  def unpack(%{"payload" => encoded}) do
    encoded |> Base.decode64!() |> :erlang.binary_to_term([:safe])
  end
end
