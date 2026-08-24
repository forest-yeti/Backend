defmodule BlockPoker.History.Workers.PersistTournamentResult do
  @moduledoc """
  Запись итога одного турнирного входа.

  Момент записи — вылет игрока, а не завершение турнира: турнир идёт
  часами, `TournamentServer` может упасть или быть перезапущен деплоем, и
  батч в конце — единственная точка, потеря которой стирает результаты
  всех участников сразу.

  Идемпотентность даёт unique-индекс по `entry_id`, поэтому дозапись при
  завершении турнира просто не находит, что дописать.
  """

  use Oban.Worker, queue: :history, max_attempts: 10

  require Logger

  alias BlockPoker.History
  alias BlockPoker.History.Writer

  @impl true
  def perform(%Oban.Job{args: args}) do
    %{result: attrs} = Writer.unpack(args)

    case History.write_tournament_result(attrs) do
      {:ok, _outcome} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "history: tournament result failed entry=#{attrs[:entry_id]} #{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
