defmodule BlockPoker.History.Workers.PersistHand do
  @moduledoc """
  Запись одной раздачи. Ретраи — на Oban с экспоненциальной паузой;
  исчерпанная задача пишет ошибку в лог с `hand_id`, но никогда не роняет
  стол: стола к этому моменту в цепочке уже нет.

  Задача идемпотентна: `hands.id` заведён в момент старта раздачи, и
  повтор находит её записанной.
  """

  use Oban.Worker, queue: :history, max_attempts: 10

  require Logger

  alias BlockPoker.History
  alias BlockPoker.History.Writer

  @impl true
  def perform(%Oban.Job{args: args}) do
    %{rows: rows} = Writer.unpack(args)

    case History.write(rows) do
      {:ok, _outcome} ->
        :ok

      {:error, reason} ->
        Logger.error("history: write failed hand=#{rows.hand.id} #{inspect(reason)}")
        {:error, reason}
    end
  end
end
