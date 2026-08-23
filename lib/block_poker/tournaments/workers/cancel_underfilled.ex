defmodule BlockPoker.Tournaments.Workers.CancelUnderfilled do
  @moduledoc """
  Отменяет турнир, не набравший минимума, и возвращает всё уплаченное.

  Ставится в очередь на момент `starts_at + cancel_refund_grace_seconds`
  — то есть на крайний срок ожидания, а не на секунду старта: рубить
  вечер ровно в 21:30 из-за одного недостающего человека незачем.

  ## Почему джоба, а не таймер процесса

  Возврат денег обязан произойти, даже если нода перезагрузилась между
  анонсом и стартом. Таймер `Process.send_after/3` этого не переживёт,
  а строка в `oban_jobs` переживёт: после рестарта джоба просто
  выполнится с опозданием, и игроки получат взносы обратно.

  ## Почему безопасно выполнять повторно

  `Tournaments.cancel/1` отказывается отменять начавшийся турнир и
  строит возвраты по ключам идемпотентности. Джоба, выполненная дважды
  или выполнившаяся после успешного старта, ничего не сломает: в первом
  случае UNIQUE погасит вторые записи, во втором отказ придёт до
  единой записи в журнал.
  """

  use Oban.Worker, queue: :tournaments, max_attempts: 5

  alias BlockPoker.Tournaments
  alias BlockPoker.Tournaments.Tournament

  require Logger

  @doc """
  Ставит отмену в очередь на крайний срок ожидания.

  `unique` по аргументам: анонс, повторённый тиком планировщика, не
  должен плодить десяток одинаковых отмен на один вечер.
  """
  @spec schedule(Tournament.t(), DateTime.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def schedule(%Tournament{} = tournament, %DateTime{} = deadline) do
    %{tournament_id: tournament.id}
    |> __MODULE__.new(scheduled_at: deadline, unique: [period: :infinity, keys: [:tournament_id]])
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tournament_id" => tournament_id}}) do
    with {:ok, tournament} <- Tournaments.get_tournament(tournament_id) do
      decide(tournament)
    end
  end

  # Набор считается по **людям**, а не по входам: порог старта — про
  # то, сколько человек сядет за столы, а не сколько раз заплатили.
  defp decide(%Tournament{} = tournament) do
    cond do
      not Tournament.pre_game?(tournament) ->
        # Турнир успел стартовать: отменять нечего, и это не ошибка.
        :ok

      tournament.players_count >= tournament.setting.min_players ->
        :ok

      true ->
        cancel(tournament)
    end
  end

  defp cancel(tournament) do
    case Tournaments.cancel(tournament.id) do
      {:ok, refunded} ->
        Logger.info(
          "турнир #{tournament.id} отменён по недобору " <>
            "(#{tournament.players_count} из #{tournament.setting.min_players}), " <>
            "возвратов: #{refunded}"
        )

        :ok

      {:error, :tournament_started} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
