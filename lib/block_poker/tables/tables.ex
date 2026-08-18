defmodule BlockPoker.Tables do
  @moduledoc """
  Публичный API столов: всё, что канал вправе вызвать, — здесь.

  Порядок посадки строгий и он важен (§4 задачи 3):

    1. резерв места в `TableServer` — атомарно, потому что следующий шаг
       ходит в БД, а место всё это время не должно достаться другому;
    2. списание из кошелька через ledger с ключом `buyin:<reservation_id>`;
    3. подтверждение резерва — место занято, стек равен бай-ину;
    4. если шаг 2 упал, резерв снимается.

  Обратный порядок (сначала посадить, потом списать) даёт стол, за которым
  сидит игрок без денег; порядок «списать, потом сажать» — деньги, ушедшие
  в никуда, если место успели занять.

  Ни одного исхода, в котором фишки появились из воздуха или пропали, здесь
  нет — это и есть инвариант денег.
  """

  alias BlockPoker.Accounts
  alias BlockPoker.GameMode
  alias BlockPoker.Tables.{Lobby, RoomState, TableRegistry, TableServer}

  @type entry :: :wait_bb | :post
  @type error :: atom()

  @spec lobby_snapshot() :: [map()]
  def lobby_snapshot, do: Lobby.snapshot()

  @spec room_state(Ecto.UUID.t()) :: {:ok, RoomState.t()} | {:error, :not_found}
  def room_state(room_id) do
    with {:ok, pid} <- fetch_room(room_id), do: {:ok, TableServer.state(pid)}
  end

  @doc """
  Посадка на конкретное место конкретной комнаты — путь «игрок открыл стол
  из лобби и выбрал место мышью».

  `entry` — намерение, а не решение: правила (хедз-ап, место на большом
  блайнде, окно возврата) могут потребовать иного, и решает их контекст.
  """
  @spec join_seat(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, error()}
  def join_seat(room_id, user_id, seat, buy_in, opts \\ []) do
    with {:ok, pid} <- fetch_room(room_id) do
      seat_player(pid, room_id, user_id, seat, buy_in, entry(opts))
    end
  end

  @doc """
  Быстрый вход: запрос адресуется **шаблону**, а не комнате — игрок выбирает
  лимит (NL2, NL10), а не конкретный стол.

  Если между выбором комнаты и резервом её успели заполнить, попытка
  повторяется на следующей: игрок нажал «сесть за NL10», и его волнует
  лимит, а не комната.
  """
  @spec quick_seat(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, error()}
  def quick_seat(setting_id, user_id, buy_in, opts \\ []) do
    attempts = Lobby.rooms_for(setting_id) |> Enum.sort_by(&{-&1.seats_taken, &1.room_id})
    try_rooms(attempts, user_id, buy_in, entry(opts), :no_seats_available)
  end

  @doc """
  Уход из-за стола: стек возвращается в кошелёк записью `cash_out`.

  Место освобождается **после** подтверждения перевода — до тех пор оно
  занято уходящим. Обратный порядок оставил бы фишки без владельца, если
  перевод упал.
  """
  @spec leave_seat(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, error()}
  def leave_seat(room_id, user_id) do
    with {:ok, pid} <- fetch_room(room_id),
         room = TableServer.state(pid),
         {:ok, seat} <- fetch_seat(room, user_id),
         :ok <- ensure_can_leave(room, seat),
         {:ok, %{ref: ref, stack: stack}} <- TableServer.begin_leave(pid, user_id) do
      case GameMode.Cash.return_chips(room, user_id, stack, ref) do
        :ok ->
          TableServer.finish_leave(pid, ref)
          {:ok, %{room_id: room_id, cashed_out: stack}}

        {:error, reason} ->
          TableServer.cancel_leave(pid, ref, stack)
          {:error, reason}
      end
    end
  end

  @doc """
  Докупка. Разрешена между раздачами в любой момент, независимо от текущего
  стека; верх ограничен `max_buy_in`. Во время раздачи запрещена: докупка
  на ходу меняет эффективный стек посреди торговли и ломает уже сделанные
  ставки.
  """
  @spec add_chips(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer()) :: {:ok, map()} | {:error, error()}
  def add_chips(room_id, user_id, amount) do
    with {:ok, pid} <- fetch_room(room_id),
         {:ok, ref} <- TableServer.validate_add_chips(pid, user_id, amount),
         room = TableServer.state(pid),
         :ok <- GameMode.Cash.take_buy_in(room, user_id, amount, ref),
         {:ok, seat} <- TableServer.commit_add_chips(pid, user_id, amount) do
      {:ok, %{room_id: room_id, seat: seat.number, stack: seat.stack}}
    end
  end

  @spec sit_out(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | {:error, error()}
  def sit_out(room_id, user_id) do
    with {:ok, pid} <- fetch_room(room_id), do: TableServer.sit_out(pid, user_id)
  end

  @spec sit_in(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | {:error, error()}
  def sit_in(room_id, user_id) do
    with {:ok, pid} <- fetch_room(room_id), do: TableServer.sit_in(pid, user_id)
  end

  @doc "Разрыв соединения — не cash-out: место держится grace-период."
  @spec disconnect(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | {:error, error()}
  def disconnect(room_id, user_id) do
    with {:ok, pid} <- fetch_room(room_id), do: TableServer.disconnect(pid, user_id)
  end

  @spec reconnect(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, RoomState.t()} | {:error, error()}
  def reconnect(room_id, user_id) do
    with {:ok, pid} <- fetch_room(room_id),
         {:ok, _seat} <- TableServer.reconnect(pid, user_id) do
      {:ok, TableServer.state(pid)}
    end
  end

  @doc "Сидит ли игрок в этой комнате — для авторизации подписки на топик."
  @spec seated?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def seated?(room_id, user_id) do
    case room_state(room_id) do
      {:ok, room} -> RoomState.find_seat(room, user_id) != nil
      {:error, _reason} -> false
    end
  end

  defp try_rooms([], _user_id, _buy_in, _entry, reason), do: {:error, reason}

  defp try_rooms([room | rest], user_id, buy_in, entry, _reason) do
    case seat_player(room.pid, room.room_id, user_id, :first_free, buy_in, entry) do
      {:ok, result} ->
        {:ok, result}

      # Место или комнату успели занять — идём в следующую комнату.
      {:error, reason} when reason in [:seat_taken, :no_seats_available, :room_closing] ->
        try_rooms(rest, user_id, buy_in, entry, reason)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp seat_player(pid, room_id, user_id, seat, buy_in, entry) do
    with {:ok, %{reservation_id: reservation_id}} <-
           TableServer.reserve_seat(pid, user_id, seat, buy_in, profile(user_id)) do
      room = TableServer.state(pid)

      case GameMode.Cash.take_buy_in(room, user_id, buy_in, reservation_id) do
        :ok ->
          confirm(pid, room_id, user_id, reservation_id, buy_in, entry)

        {:error, reason} ->
          TableServer.release_seat(pid, reservation_id)
          {:error, reason}
      end
    end
  end

  defp confirm(pid, room_id, user_id, reservation_id, buy_in, entry) do
    case TableServer.confirm_seat(pid, reservation_id, buy_in, entry) do
      {:ok, seat} ->
        {:ok,
         %{
           room_id: room_id,
           seat: seat.number,
           stack: seat.stack,
           waiting_for_bb: seat.waiting_for_bb,
           can_post: seat.can_post
         }}

      {:error, reason} ->
        # Резерв потерян (комната перезапустилась) — деньги надо вернуть,
        # иначе бай-ин остался бы списанным без места за столом.
        room = TableServer.state(pid)
        GameMode.Cash.return_chips(room, user_id, buy_in, reservation_id)
        {:error, reason}
    end
  end

  # Профиль снимается один раз, при посадке: стол показывает игрока ником,
  # а не UUID, и не ходит в базу на каждый снапшот.
  defp profile(user_id) do
    case Accounts.get_user(user_id) do
      {:ok, user} -> %{name: user.name, avatar: user.avatar}
      {:error, _reason} -> %{}
    end
  end

  defp ensure_can_leave(room, seat) do
    if GameMode.Cash.can_leave?(room, seat), do: :ok, else: {:error, :hand_in_progress}
  end

  defp fetch_seat(room, user_id) do
    case RoomState.find_seat(room, user_id) do
      nil -> {:error, :not_seated}
      seat -> {:ok, seat}
    end
  end

  defp fetch_room(room_id) do
    case TableRegistry.whereis(room_id) do
      nil -> {:error, :not_found}
      pid -> {:ok, pid}
    end
  end

  defp entry(opts) do
    case Keyword.get(opts, :entry, :wait_bb) do
      :post -> :post
      _other -> :wait_bb
    end
  end
end
