defmodule BlockPoker.History.Workers.RevealCards do
  @moduledoc """
  Второй, маленький апдейт видимости карт.

  Показ бывает **после** записи раздачи: окно добровольного показа живёт
  паузу между раздачами, а запись уходит в БД сразу по завершении. Ждать
  окно запись не имеет права — иначе следующая раздача упрётся в
  предыдущую (§4 задачи 6).
  """

  use Oban.Worker, queue: :history, max_attempts: 5

  alias BlockPoker.History
  alias BlockPoker.History.Writer

  @impl true
  def perform(%Oban.Job{args: args}) do
    %{hand_id: hand_id, user_ids: user_ids} = Writer.unpack(args)
    {:ok, _count} = History.mark_voluntary(hand_id, user_ids)
    :ok
  end
end
