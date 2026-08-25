defmodule BlockPoker.Tournaments.Workers.SettleTournament do
  @moduledoc """
  Дорасчёт турнира: страховка на случай, если выплата не прошла в момент
  окончания.

  Обычно призы платит `TournamentServer` сразу, как определился
  победитель, — одной транзакцией на весь турнир. Эта джоба существует
  для случая, когда та транзакция не состоялась: процесс упал между
  последней раздачей и выплатой, нода перезагрузилась, база была
  недоступна секунду.

  ## Почему это безопасно повторять

  Выплата идёт по ключам идемпотентности, построенным от входа
  (`tournament:<tid>:prize:<entry_id>`), и повторный вызов не начисляет
  второй раз — это гарантирует UNIQUE в `wallet_entries`, а не проверка
  в коде. Уже законченный турнир джоба не трогает вовсе.

  ## Чего она не делает

  Не определяет победителя и не считает места. Если турнир не доигран,
  джоба ничего не решает: доигрывать за игроков нельзя, и «выплатить
  как есть» означало бы раздать призы за незаконченную игру. Такой
  турнир остаётся оператору.
  """

  use Oban.Worker, queue: :tournaments, max_attempts: 5

  alias BlockPoker.Tournaments
  alias BlockPoker.Tournaments.{Entry, Tournament}

  require Logger

  @doc "Ставит дорасчёт в очередь. Ключ уникальности — сам турнир."
  @spec schedule(Ecto.UUID.t(), DateTime.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def schedule(tournament_id, %DateTime{} = at) do
    %{tournament_id: tournament_id}
    |> __MODULE__.new(scheduled_at: at, unique: [period: :infinity, keys: [:tournament_id]])
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tournament_id" => tournament_id}}) do
    with {:ok, tournament} <- Tournaments.get_tournament(tournament_id) do
      settle(tournament)
    end
  end

  defp settle(%Tournament{status: :finished}), do: :ok

  defp settle(%Tournament{} = tournament) do
    case results(tournament) do
      {:ok, results} ->
        case Tournaments.settle(tournament, results) do
          {:ok, _payouts} ->
            Logger.warning(
              "турнир #{tournament.id} рассчитан джобой: выплата в процессе не прошла"
            )

            :ok

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :not_finished} ->
        # Турнир ещё идёт или завис недоигранным. Доигрывать за игроков
        # джоба не вправе, и раздавать призы за незаконченную игру — тоже.
        Logger.warning("турнир #{tournament.id} не доигран: дорасчёт пропущен")

        :ok
    end
  end

  # Победитель — единственный, кто не вылетел. Пока таких больше одного,
  # турнир не закончен, и результата не существует.
  defp results(%Tournament{} = tournament) do
    entries = Tournaments.list_entries(tournament.id)

    busted = Enum.filter(entries, &(&1.status in [:busted, :paid] and &1.place != nil))
    alive = Enum.filter(entries, &Entry.seated?/1)

    case alive do
      [winner] ->
        # `shared_places` едут из БД: слитые места одновременного вылета
        # делятся поровну, и дорасчёт обязан заплатить то же, что уже
        # объявили игроку при вылете (`Tournaments.share_of_places/3`).
        places =
          Enum.map(busted, fn entry ->
            %{
              entry_id: entry.id,
              place: entry.place,
              shared_places: entry.shared_places || [entry.place]
            }
          end)

        {:ok, [%{entry_id: winner.id, place: 1, shared_places: [1]} | places]}

      _more ->
        {:error, :not_finished}
    end
  end
end
