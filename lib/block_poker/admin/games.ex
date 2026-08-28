defmodule BlockPoker.Admin.Games do
  @moduledoc """
  Живые игры всех четырёх режимов одним списком.

  Один список с полем `kind`, а не четыре эндпоинта, потому что панели
  нужен ответ на вопрос «что сейчас происходит в руме», а он один. Режимы
  различаются полями, а не структурой ответа, и различия эти спрашиваются
  у самого режима (`GameMode`), а не выбираются ветвлением по типу стола:
  `kind` — это `mode.game_mode_id()`, а не догадка по настройкам.

  Источник — процессы, а не БД: состояние активного стола живёт в
  `TableServer`, и второй, «читающей» модели у него нет и не будет
  (§7 CLAUDE.md).

  Комнаты берутся из реестра, а не из пулов лобби: столы идущего MTT
  принадлежат турниру и в витрине не показываются, а надзору нужны и они.
  """

  alias BlockPoker.Admin.{Audit, Context}
  alias BlockPoker.Tables
  alias BlockPoker.Tables.{RoomState, TableRegistry, TableServer}
  alias BlockPoker.Tournaments
  alias BlockPoker.Tournaments.TournamentServer

  @kinds [:cash, :sit_and_go, :mtt, :ofc_cash]

  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc """
  Вид игры из строки с провода. `:all` — фильтра нет.

  Живёт в ядре по той же причине, по какой здесь живёт сам список:
  «какие бывают режимы» — доменное знание, и его копия в транспорте
  разошлась бы с этой на первом же новом режиме (§3 CLAUDE.md).
  """
  @spec kind(term()) :: atom()
  def kind(value) when value in [nil, "", "all"], do: :all

  def kind(value) when is_binary(value) do
    Enum.find(@kinds, :all, &(Atom.to_string(&1) == value))
  end

  def kind(value) when value in @kinds, do: value
  def kind(_value), do: :all

  @doc """
  Топики, на которых слышно изменение списка: комнаты рассказывают о себе
  в один, турниры — в другой.

  Живут здесь, а не в канале, ровно потому же, почему здесь живёт сам
  список: из чего он собран, знает ядро.
  """
  @spec topics() :: [String.t()]
  def topics, do: [TableServer.rooms_topic(), Tournaments.lobby_topic()]

  @doc "Топик конкретного турнира: на нём слышен его ход."
  @spec topic(Ecto.UUID.t()) :: String.t()
  defdelegate topic(tournament_id), to: Tournaments

  @doc """
  Список живых игр. `:all` — все режимы сразу.

  Турниры (`:mtt`) — это **не** столы: у турнира своя карточка, а его
  столы попадают в список отдельными строками кэшевого вида, потому что
  наблюдать можно именно за столом.
  """
  @spec live_games(atom()) :: [map()]
  def live_games(kind \\ :all) do
    (rooms() ++ tournaments())
    |> Enum.filter(&(kind == :all or &1.kind == kind))
    |> Enum.sort_by(&{&1.kind, &1.name, &1.id})
  end

  @doc "Карточка одной игры: то же, что строка списка, плюс состав участников."
  @spec game_card(atom(), String.t()) :: {:ok, map()} | {:error, :admin_room_not_found}
  def game_card(:mtt, id) do
    case tournament_card(id) do
      nil -> {:error, :admin_room_not_found}
      card -> {:ok, card}
    end
  end

  def game_card(_kind, id) do
    case Tables.room_state(id) do
      {:ok, room} -> {:ok, room_card(room)}
      {:error, _reason} -> {:error, :admin_room_not_found}
    end
  end

  @doc """
  Останавливает идущий турнир: столы замирают, часы уровня стоят.

  Три операции ниже — единственное, что панель делает с игрой, а не с
  игроком, и правило у них общее: **решает контекст, исполняет процесс.**
  Панель не знает ни про `Registry`, ни про то, что пауза это ещё и
  строка в `tournaments`.

  Журнал пишется отдельной записью, а не шагом транзакции, и порядок
  здесь обратный обычному: сперва `Audit.ensure_reason/2`, потом
  действие, потом запись. Причина — процесс: остановка турнира это
  `GenServer.call`, и завернуть его в `Ecto.Multi` вместе с записью
  нельзя. Проверка причины до действия закрывает ровно ту дыру, ради
  которой запись обычно и делают транзакционной: без причины ничего не
  происходит.
  """
  @spec pause_tournament(Context.t(), Ecto.UUID.t(), String.t() | nil) ::
          {:ok, map()} | {:error, atom()}
  def pause_tournament(%Context{} = ctx, tournament_id, reason) do
    control(ctx, tournament_id, :pause_tournament, reason, &TournamentServer.pause/1)
  end

  @doc "Снимает паузу: уровень доигрывает свой остаток, столы раздают."
  @spec resume_tournament(Context.t(), Ecto.UUID.t(), String.t() | nil) ::
          {:ok, map()} | {:error, atom()}
  def resume_tournament(%Context{} = ctx, tournament_id, reason) do
    control(ctx, tournament_id, :resume_tournament, reason, &TournamentServer.resume/1)
  end

  @doc """
  Снимает турнир целиком: возвраты всем, столы гаснут.

  Единственная из трёх, что работает и **без процесса**. Турнир, чей
  процесс не поднялся, — это и есть тот случай, ради которого ручка
  нужна: в БД он идёт, раздавать некому, и снять его иначе нечем.
  """
  @spec cancel_tournament(Context.t(), Ecto.UUID.t(), String.t() | nil) ::
          {:ok, map()} | {:error, atom()}
  def cancel_tournament(%Context{} = ctx, tournament_id, reason) do
    attrs = audit_attrs(:cancel_tournament, tournament_id, reason)

    with :ok <- Audit.ensure_reason(ctx, attrs),
         {:ok, refunded} <- do_cancel_tournament(tournament_id) do
      Audit.write(ctx, put_in(attrs[:meta], %{refunded: refunded}))

      {:ok, %{id: tournament_id, status: :cancelled, refunded: refunded}}
    end
  end

  defp do_cancel_tournament(tournament_id) do
    case TournamentServer.whereis(tournament_id) do
      nil -> Tournaments.abort(tournament_id)
      pid -> TournamentServer.abort(pid)
    end
  end

  defp control(ctx, tournament_id, action, reason, fun) do
    attrs = audit_attrs(action, tournament_id, reason)

    with :ok <- Audit.ensure_reason(ctx, attrs),
         {:ok, pid} <- fetch_server(tournament_id),
         :ok <- fun.(pid) do
      Audit.write(ctx, attrs)

      game_card(:mtt, tournament_id)
    end
  end

  # Турнир без процесса остановить нельзя: останавливать нечего.
  # Отдельный код, а не `admin_room_not_found`, — панели важно различать
  # «нет такого турнира» и «турнир есть, но он не идёт».
  defp fetch_server(tournament_id) do
    case TournamentServer.whereis(tournament_id) do
      nil -> {:error, :tournament_not_running}
      pid -> {:ok, pid}
    end
  end

  defp audit_attrs(action, tournament_id, reason) do
    %{
      action: action,
      subject_type: :tournament,
      subject_id: tournament_id,
      reason: reason,
      meta: %{}
    }
  end

  defp rooms do
    TableRegistry.live_tables()
    |> Enum.flat_map(fn {room_id, _pid} ->
      case Tables.room_state(room_id) do
        {:ok, room} -> [room_card(room)]
        {:error, _reason} -> []
      end
    end)
  end

  defp room_card(%RoomState{} = room) do
    players = RoomState.players(room)

    %{
      kind: room.mode.game_mode_id(),
      id: room.room_id,
      setting_id: room.setting.id,
      name: room.mode.display_name(room),
      game_type: room.setting.game_type,
      discipline: room.discipline.id(),
      currency: room.setting.currency,
      status: status(room),
      players: length(players),
      seats: room.setting.max_players,
      pot: pot(room),
      hand_no: room.hands_played,
      # Наблюдение — свойство стола, а не режима: смотреть можно за любым
      # живым столом, включая турнирный.
      observable: true,
      participants: Enum.map(players, &participant(room, &1)),
      extra: extra(room)
    }
  end

  # Состояние комнаты словами надзора: «набирается», «играет»,
  # «закрывается». Считается по данным комнаты, а не по её типу.
  defp status(%RoomState{draining?: true}), do: :closing
  defp status(%RoomState{game_started?: true}), do: :running
  defp status(%RoomState{}), do: :waiting

  # Банк идущей раздачи. Спрашивается у дисциплины: у китайского покера
  # банка нет вовсе, и `nil` здесь — честный ответ, а не ноль.
  defp pot(%RoomState{hand: nil}), do: nil

  defp pot(%RoomState{hand: hand} = room) do
    hand |> room.discipline.public_view() |> Map.get(:pot)
  end

  defp participant(room, seat) do
    %{
      user_id: seat.user_id,
      name: seat.name,
      seat: seat.number,
      stack: seat.stack,
      status: seat.status,
      acting: acting?(room, seat.number)
    }
  end

  defp acting?(%RoomState{hand: nil}, _seat), do: false
  defp acting?(%RoomState{hand: hand} = room, seat), do: room.discipline.to_act(hand) == seat

  # Поля, специфичные для режима. Собираются в ядре и одинаковым способом
  # для всех: номиналы спрашиваются у режима, остальное — у шаблона, если
  # оно у него есть. Ветвления по `kind` здесь нет и быть не должно.
  defp extra(%RoomState{} = room) do
    %{
      limits: room.mode.limits(room),
      bet_unit: RoomState.bet_unit(room),
      buy_in: Map.get(room.setting, :buy_in),
      starting_stack: Map.get(room.setting, :starting_stack),
      code: Map.get(room.setting, :code),
      # Турнирный блок комнаты либо `nil` — за кэш-столом его нет.
      tournament: room.tournament && tournament_block(room)
    }
  end

  defp tournament_block(%RoomState{tournament: tournament} = room) do
    %{
      level: tournament.level,
      prize: tournament.prize,
      players_left: RoomState.alive_count(room),
      paused: room.paused?,
      finished: tournament.settled?
    }
  end

  defp tournaments do
    TableRegistry.live_tournaments()
    |> Enum.flat_map(fn {tournament_id, _pid} ->
      case tournament_card(tournament_id) do
        nil -> []
        card -> [card]
      end
    end)
  end

  defp tournament_card(tournament_id) do
    with {:ok, tournament} <- Tournaments.get_tournament(tournament_id),
         pid when is_pid(pid) <- TournamentServer.whereis(tournament_id) do
      snapshot = TournamentServer.state(pid)

      %{
        kind: :mtt,
        id: tournament.id,
        setting_id: tournament.tournament_setting_id,
        name: tournament.setting.name,
        game_type: tournament.setting.game_type,
        currency: tournament.setting.currency,
        status: snapshot.status,
        players: snapshot.players_left,
        seats: snapshot.entries,
        pot: nil,
        hand_no: snapshot.hands_played,
        # Наблюдать можно за столом турнира, а не за самим турниром:
        # карт у турнира нет, они у столов.
        observable: false,
        participants: Enum.map(TournamentServer.players(pid), &tournament_player/1),
        extra: %{
          level: snapshot.level,
          limits: snapshot.limits,
          next_level_in_ms: snapshot.next_level_in_ms,
          on_break: snapshot.on_break,
          paused: snapshot.paused,
          break_ends_in_ms: snapshot.break_ends_in_ms,
          tables: snapshot.tables,
          entries: snapshot.entries,
          paid_places: snapshot.paid_places,
          final_table: snapshot.final_table,
          prize_pool: tournament.prize_pool,
          started_at: tournament.started_at
        }
      }
    else
      _other -> nil
    end
  end

  defp tournament_player(player) do
    %{
      user_id: player.user_id,
      entry_id: player.entry_id,
      table_id: player.table_id,
      seat: player.seat,
      stack: player.stack,
      status: if(player.alive?, do: :playing, else: :busted)
    }
  end
end
