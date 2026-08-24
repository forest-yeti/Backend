defmodule BlockPoker.History.Workers.Prune do
  @moduledoc """
  Суточная чистка раздач старше срока хранения.

  Удаляются `hands` и `ofc_hands`; участники и действия уезжают каскадом
  по внешнему ключу. **`player_stats_daily` и `tournament_results` не
  трогаются никогда**: пожизненные winrate, VPIP, EV, места и призы
  остаются — теряется только возможность открыть конкретную старую
  раздачу.

  Удаление идёт **пачками с ограничением**, а не одним `DELETE`: длинный
  `DELETE` на MySQL держит блокировки и растит undo-лог, а это та же
  таблица, в которую в этот момент пишутся живые раздачи.
  """

  use Oban.Worker, queue: :history, max_attempts: 3

  import Ecto.Query

  require Logger

  alias BlockPoker.History
  alias BlockPoker.History.{HandRecord, OfcHand}
  alias BlockPoker.Repo

  @batch 5_000

  @impl true
  def perform(%Oban.Job{}) do
    cutoff = DateTime.add(DateTime.utc_now(), -History.retention_days() * 86_400, :second)

    holdem = prune(HandRecord, cutoff)
    ofc = prune(OfcHand, cutoff)

    Logger.info("history: pruned hands=#{holdem} ofc=#{ofc} before=#{cutoff}")
    :ok
  end

  defp prune(schema, cutoff, deleted \\ 0) do
    ids =
      schema
      |> where([h], h.ended_at < ^cutoff)
      |> order_by([h], asc: h.ended_at)
      |> limit(@batch)
      |> select([h], h.id)
      |> Repo.all()

    case ids do
      [] ->
        deleted

      ids ->
        {count, _rows} = schema |> where([h], h.id in ^ids) |> Repo.delete_all()
        prune(schema, cutoff, deleted + count)
    end
  end
end
