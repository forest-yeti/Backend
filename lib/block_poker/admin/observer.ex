defmodule BlockPoker.Admin.Observer do
  @moduledoc """
  God-mode: наблюдение за столом с открытыми картами и сырой лентой
  запросов.

  **Временный отладочный инструмент.** Живёт в трёх файлах — этом,
  `Socket.Channels.Admin.RoomChannel` и `Socket.Views.Admin.RoomView`, —
  и вырезается одним коммитом перед публичным релизом (§13 задачи 8).
  Поэтому ни `TableView`, ни `RoomState` ради него не меняются: ядро **не
  получает** ни одной функции вида «отдай состояние без фильтрации» за
  пределами этого модуля, и тест приватности игрока остаётся зелёным без
  единого исключения.

  По умолчанию режим **выключен**: `config :block_poker, :admin_observer,
  enabled: false`. При выключенном флаге `observe/2` отвечает кодом, и
  вкладка «Стол» в панели не показывается.

  Процесс держит кольцевой буфер последних 500 событий на стол, чтобы
  админ, открывший стол в середине раздачи, увидел её начало. Буфер живёт
  в памяти и умирает вместе с процессом: ленты в БД нет (§6 задачи 8).

  Единственный потребитель telemetry-события `[:block_poker, :table,
  :intent]`. Само событие полезно для метрик и карт не раскрывает, поэтому
  переживёт удаление наблюдения.
  """

  use GenServer

  alias BlockPoker.Admin.{Audit, Auth, Context}
  alias BlockPoker.Tables
  alias BlockPoker.Tables.{RoomState, TableServer}
  alias Phoenix.PubSub

  @pubsub BlockPoker.PubSub
  @buffer_size 500
  @telemetry [:block_poker, :table, :intent]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Отладочный топик стола. Обычный `room_events:<id>` при этом не трогается."
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(room_id), do: "table_debug:#{room_id}"

  @spec enabled?() :: boolean()
  def enabled? do
    :block_poker
    |> Application.get_env(:admin_observer, [])
    |> Keyword.get(:enabled, false)
  end

  @doc """
  Открыть наблюдение: подписаться на оба топика стола и получить полный
  несфильтрованный снапшот вместе с лентой предыдущих событий.

  Подписка делается от имени **вызывающего** процесса — канала: он и есть
  подписчик, такой же, как любой другой (§6 задачи 8).
  """
  @spec observe(Context.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, atom()}
  def observe(%Context{} = ctx, room_id) do
    with :ok <- ensure_enabled(),
         {:ok, _admin} <- Auth.ensure_admin(ctx.admin_id),
         {:ok, room} <- fetch_room(room_id) do
      :ok = PubSub.subscribe(@pubsub, TableServer.topic(room_id))
      :ok = PubSub.subscribe(@pubsub, topic(room_id))

      Audit.write(ctx, %{
        action: :observe_room_open,
        subject_type: :room,
        subject_id: room_id
      })

      {:ok, %{room: snapshot(room), feed: feed(room_id)}}
    end
  end

  @doc "Закрыть наблюдение. Запись в журнале переживёт сам режим (§13 задачи 8)."
  @spec stop_observing(Context.t(), Ecto.UUID.t()) :: :ok
  def stop_observing(%Context{} = ctx, room_id) do
    PubSub.unsubscribe(@pubsub, TableServer.topic(room_id))
    PubSub.unsubscribe(@pubsub, topic(room_id))

    Audit.write(ctx, %{
      action: :observe_room_close,
      subject_type: :room,
      subject_id: room_id
    })

    :ok
  end

  @doc """
  Полный несфильтрованный снапшот стола: стеки, поты, борд, **все**
  карманные карты и остаток колоды.

  Seed RNG наружу не уходит: по seed воспроизводится будущее, по остатку
  колоды — только настоящее (§8 задачи 8).
  """
  @spec snapshot(RoomState.t()) :: map()
  def snapshot(%RoomState{} = room) do
    %{
      room_id: room.room_id,
      name: room.mode.display_name(room),
      kind: room.mode.game_mode_id(),
      discipline: room.discipline.id(),
      # Масштаб сумм снапшота: `main` считается в центах, `play_money` — в
      # целых фишках. Без валюты панель не может показать ни один стек, не
      # угадывая, а угадывание здесь означает ошибку ровно в сто раз.
      currency: room.setting.currency,
      phase: room.phase,
      action_seq: room.action_seq,
      hands_played: room.hands_played,
      button_seat: room.button_seat,
      paused: room.paused?,
      draining: room.draining?,
      seats: Enum.map(RoomState.seats(room), &seat/1),
      hand: hand(room)
    }
  end

  @doc "Лента последних событий стола — от старых к свежим."
  @spec feed(Ecto.UUID.t()) :: [map()]
  def feed(room_id), do: GenServer.call(__MODULE__, {:feed, room_id})

  @doc false
  @spec handle_intent(list(), map(), map(), term()) :: :ok
  def handle_intent(@telemetry, measurements, metadata, _config) do
    event = %{
      at: DateTime.utc_now(),
      user_id: metadata[:user_id],
      seat: metadata[:seat],
      topic: metadata[:topic],
      event: metadata[:event],
      payload: metadata[:payload],
      seq: metadata[:seq],
      outcome: metadata[:outcome],
      code: metadata[:code],
      latency_us: System.convert_time_unit(measurements[:duration] || 0, :native, :microsecond)
    }

    GenServer.cast(__MODULE__, {:intent, metadata[:room_id], event})
  end

  @impl true
  def init(_opts) do
    if enabled?() do
      :telemetry.attach(
        "admin-observer-intent",
        @telemetry,
        &__MODULE__.handle_intent/4,
        nil
      )
    end

    {:ok, %{feeds: %{}}}
  end

  @impl true
  def handle_call({:feed, room_id}, _from, state) do
    {:reply, state.feeds |> Map.get(room_id, []) |> Enum.reverse(), state}
  end

  @impl true
  def handle_cast({:intent, nil, _event}, state), do: {:noreply, state}

  def handle_cast({:intent, room_id, event}, state) do
    # Лента и рассылка — одно и то же событие: подписчик, подключившийся
    # позже, увидит его в буфере, подключившийся раньше — сразу.
    PubSub.broadcast(@pubsub, topic(room_id), {:admin_intent, event})

    feed = state.feeds |> Map.get(room_id, []) |> push(event)

    {:noreply, %{state | feeds: Map.put(state.feeds, room_id, feed)}}
  end

  # Буфер хранится головой вперёд: список только растёт с головы, а
  # разворачивается один раз, при выдаче.
  defp push(feed, event), do: [event | Enum.take(feed, @buffer_size - 1)]

  defp ensure_enabled do
    if enabled?(), do: :ok, else: {:error, :admin_observer_disabled}
  end

  defp fetch_room(room_id) do
    case Tables.room_state(room_id) do
      {:ok, room} -> {:ok, room}
      {:error, _reason} -> {:error, :admin_room_not_found}
    end
  end

  defp seat(seat) do
    %{
      seat: seat.number,
      status: seat.status,
      user_id: seat.user_id,
      name: seat.name,
      stack: seat.stack,
      sitting_out: seat.sit_out_pending,
      # Заранее выбранное действие: игроку соседей оно не показывается
      # никогда, отладке — показывается, в этом и смысл режима.
      preselect: seat.preselect,
      straddle: seat.straddle
    }
  end

  # Раздача целиком: публичная часть, карманные карты **всех** мест и
  # остаток колоды. Ничего не фильтруется — режим существует ровно ради
  # полной картины.
  defp hand(%RoomState{hand: nil}), do: nil

  defp hand(%RoomState{hand: hand} = room) do
    hand
    |> room.discipline.public_view()
    |> Map.merge(%{
      hole_cards:
        Map.new(room.discipline.hole_cards(hand), fn {seat, cards} -> {seat, {:cards, cards}} end),
      deck: deck(hand),
      to_act: room.discipline.to_act(hand)
    })
  end

  # Остаток колоды есть не у всякой дисциплины, и её отсутствие — не
  # ошибка, а свойство игры.
  defp deck(hand) do
    case Map.get(hand, :deck) do
      cards when is_list(cards) -> {:cards, cards}
      _other -> nil
    end
  end
end
