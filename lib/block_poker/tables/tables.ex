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

  require Logger

  alias BlockPoker.Accounts
  alias BlockPoker.CashGames
  alias BlockPoker.CashGames.CashGameSetting
  alias BlockPoker.Engine.Preselect
  alias BlockPoker.Engine.Variant.Registry, as: VariantRegistry
  alias BlockPoker.GameMode
  alias BlockPoker.Reactions
  alias BlockPoker.Tables.{Lobby, LobbyQuery, RoomState, TableRegistry, TableServer}

  @type entry :: :wait_bb | :post
  @type error :: atom()

  @doc """
  Разбор фильтров и сортировки лобби из сырого payload.

  Отдельно от `lobby_snapshot/1` потому, что разобранный запрос нужен каналу
  дважды: на первичной выдаче и на каждом `lobby_delta` — чтобы не слать
  подписчику лимиты, которые он отфильтровал.
  """
  @spec lobby_query(map() | nil) :: {:ok, LobbyQuery.t()} | {:error, :validation_failed}
  def lobby_query(params \\ nil), do: LobbyQuery.parse(params)

  @spec lobby_snapshot(LobbyQuery.t()) :: [map()]
  def lobby_snapshot(query \\ %LobbyQuery{}), do: Lobby.snapshot(Lobby, query)

  @doc """
  Допустимые значения фильтров и сортировок — их же клиент рисует в панели.
  Список приходит с сервера, чтобы новая категория не требовала релиза
  клиента с захардкоженным списком.
  """
  @spec lobby_filters() :: map()
  def lobby_filters do
    %{
      game_types: VariantRegistry.ids(),
      currencies: LobbyQuery.currencies(),
      table_sizes: LobbyQuery.table_sizes(),
      limit_tiers: LobbyQuery.limit_tiers(),
      sort_fields: LobbyQuery.sort_fields()
    }
  end

  @doc "Проходит ли обновление лимита фильтр подписчика."
  @spec lobby_visible?(LobbyQuery.t(), map()) :: boolean()
  def lobby_visible?(query, snapshot), do: LobbyQuery.matches?(query, snapshot)

  @doc """
  Поиск закрытой комнаты по коду входа — единственный способ её найти:
  в общей сетке лобби такой комнаты нет.

  Отдаётся превью со всем, что нужно для решения «садиться или нет»:
  лимиты, границы бай-ина в фишках и занятость стола. Посадка потом —
  обычным `join_seat/5`, отдельного пути для кода нет.
  """
  @spec find_by_code(term()) :: {:ok, map()} | {:error, :not_found | :no_seats_available}
  def find_by_code(code) do
    with {:ok, setting} <- CashGames.get_by_code(code),
         {:ok, room} <- pick_room_for(setting) do
      {:ok,
       %{
         setting: setting,
         room_id: room.room_id,
         seats_taken: room.seats_taken,
         max_players: room.max_players,
         free_seats: room.max_players - room.seats_taken
       }}
    end
  end

  # У закрытого шаблона комната ровно одна (`CashGameSetting.room_limit/1`),
  # поэтому выбирать не из чего — но заполненную отдавать как найденную
  # нельзя: игроку нужен не адрес стола, а место за ним.
  defp pick_room_for(setting) do
    Lobby.rooms_for(setting.id)
    |> Enum.reject(& &1.draining?)
    |> Enum.filter(&(&1.seats_taken < &1.max_players))
    |> Enum.max_by(& &1.seats_taken, fn -> nil end)
    |> case do
      nil -> {:error, :no_seats_available}
      room -> {:ok, room}
    end
  end

  @doc "Границы бай-ина комнаты в фишках — их клиент рисует ползунком стека."
  @spec buy_in_range(CashGameSetting.t()) :: %{min: pos_integer(), max: pos_integer() | nil}
  def buy_in_range(%CashGameSetting{} = setting) do
    %{
      min: CashGameSetting.min_buy_in_chips(setting),
      max: CashGameSetting.max_buy_in_chips(setting)
    }
  end

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
  Где игрок сидит прямо сейчас — по всем комнатам сразу.

  Нужно лобби: закрытое окно стола не освобождает место, и без этого списка
  игрок не знает, за какой стол возвращаться, а «Сесть» отвечает ему
  `already_seated`. Место — состояние комнаты, а не сессии, поэтому список
  собирается с живых комнат, а не хранится рядом с соединением.
  """
  @spec my_seats(Ecto.UUID.t()) :: [map()]
  def my_seats(user_id) do
    Lobby.rooms()
    |> Enum.flat_map(fn room ->
      with {:ok, state} <- room_state(room.room_id),
           %{} = seat <- RoomState.find_seat(state, user_id) do
        [
          %{
            room_id: room.room_id,
            setting_id: room.setting_id,
            seat: seat.number,
            stack: seat.stack,
            status: seat.status
          }
        ]
      else
        _other -> []
      end
    end)
    |> Enum.sort_by(& &1.room_id)
  end

  @doc """
  Уход из-за стола: стек возвращается в кошелёк записью `cash_out`.

  Место освобождается **после** подтверждения перевода — до тех пор оно
  занято уходящим. Обратный порядок оставил бы фишки без владельца, если
  перевод упал.
  """
  @spec leave_seat(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, error()}
  def leave_seat(room_id, user_id) do
    # Право встать проверяет сам `begin_leave` внутри процесса комнаты.
    # Спрашивать об этом заранее по снятому снапшоту нельзя: между «посмотрел»
    # и «встал» комната успевает начать раздачу, и игрок уходит из неё вместе
    # со своим правом на банк.
    with {:ok, pid} <- fetch_room(room_id),
         {:ok, %{ref: ref, stack: stack}} <- TableServer.begin_leave(pid, user_id) do
      case GameMode.Cash.return_chips(TableServer.state(pid), user_id, stack, ref) do
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

  Порядок трёхшаговый и по той же причине, что у посадки: между проверкой и
  зачислением лежит поход в кошелёк, а за это время комната успевает начать
  раздачу или потерять место по grace-периоду. Поэтому зачисление проверяет
  условия заново и вправе отказать — а списанные деньги в этом случае
  возвращаются в кошелёк.

  Ключ идемпотентности выдаёт **комната** и закрепляет его за местом, а не
  генерирует заново на каждый вызов: двойной клик по «докупить» проходит
  проверку дважды до первого зачисления, и с новым ключом это два списания
  подряд. Повтор той же суммы получает тот же ключ — кошелёк по нему уже
  списал, а зачисление по отработавшему ключу возвращает «готово», а не
  вторую пачку фишек.
  """
  @spec add_chips(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer()) :: {:ok, map()} | {:error, error()}
  def add_chips(room_id, user_id, amount) do
    with {:ok, pid} <- fetch_room(room_id),
         {:ok, ref} <- TableServer.begin_add_chips(pid, user_id, amount),
         room = TableServer.state(pid),
         :ok <- take_buy_in(pid, room, user_id, amount, ref) do
      commit_add_chips(pid, room_id, user_id, amount, ref)
    end
  end

  # Списание не прошло: ключ надо снять с места, иначе следующая попытка
  # упрётся в «предыдущая докупка ещё не завершена» при пустом кошельке.
  defp take_buy_in(pid, room, user_id, amount, ref) do
    case GameMode.Cash.take_buy_in(room, user_id, amount, ref) do
      :ok ->
        :ok

      {:error, reason} ->
        TableServer.abort_add_chips(pid, user_id, ref)
        {:error, reason}
    end
  end

  @doc """
  Зачисление уже списанной докупки. Публична ради теста гонки: воспроизвести
  «раздача началась между проверкой и зачислением» одним вызовом `add_chips/3`
  нельзя — он синхронный.
  """
  @spec commit_add_chips(pid(), Ecto.UUID.t(), Ecto.UUID.t(), pos_integer(), String.t()) ::
          {:ok, map()} | {:error, error()}
  def commit_add_chips(pid, room_id, user_id, amount, ref) do
    case TableServer.commit_add_chips(pid, user_id, ref) do
      {:ok, seat} ->
        {:ok, %{room_id: room_id, seat: seat.number, stack: seat.stack}}

      # Повтор по уже отработавшему ключу: фишки на столе с первого раза,
      # второго списания не было (кошелёк снял дубль по `idempotency_key`),
      # и возвращать нечего. Игроку это неотличимо от успеха — им и является.
      {:already_credited, seat} ->
        {:ok, %{room_id: room_id, seat: seat.number, stack: seat.stack}}

      # Между проверкой и зачислением стол начал раздачу или место ушло —
      # деньги уже списаны, и без возврата они остались бы ни в кошельке,
      # ни на столе.
      {:error, reason} ->
        return_lost_chips(TableServer.state(pid), user_id, amount, ref)
        TableServer.abort_add_chips(pid, user_id, ref)
        {:error, reason}
    end
  end

  # Возврат сам может не пройти (кошелёк недоступен). Молчать об этом нельзя:
  # это единственная точка, где фишки могут пропасть, и она обязана быть
  # видна в логе — деньги доводятся руками по `ref`.
  defp return_lost_chips(room, user_id, amount, ref) do
    case GameMode.Cash.return_chips(room, user_id, amount, ref) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "докупка #{ref}: #{amount} списано, но не зачислено и не возвращено (#{inspect(reason)})"
        )

        :error
    end
  end

  @doc "Игровое действие: fold, check, call, {:raise, to}, :all_in."
  @spec act(Ecto.UUID.t(), Ecto.UUID.t(), term(), non_neg_integer() | nil) ::
          :ok | {:error, error()}
  def act(room_id, user_id, action, seq) do
    with {:ok, pid} <- fetch_room(room_id), do: TableServer.act(pid, user_id, action, seq)
  end

  @doc """
  Заранее выбранное действие. Пустой выбор снимает предыдущий; разбор
  строки — в `Engine.Preselect`, потому что набор вариантов доменный.
  """
  @spec preselect(Ecto.UUID.t(), Ecto.UUID.t(), term()) :: :ok | {:error, error()}
  def preselect(room_id, user_id, choice) do
    with {:ok, pid} <- fetch_room(room_id),
         {:ok, parsed} <- Preselect.parse(choice) do
      TableServer.preselect(pid, user_id, parsed)
    end
  end

  @doc """
  Объявить страддл — ставку вслепую до карт — или снять объявление (`nil`).

  Это настройка места, а не действие в раздаче: объявление держится, пока
  игрок его не снимет, и перед каждой раздачей стол даёт объявившим окно
  назвать сумму. Размер и его границы считает ядро (`Engine.Straddle`).
  """
  @spec straddle(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer() | nil) ::
          {:ok, map()} | {:error, error()}
  def straddle(room_id, user_id, amount) do
    with {:ok, pid} <- fetch_room(room_id), do: TableServer.straddle(pid, user_id, amount)
  end

  @doc """
  «Не ждать большого блайнда». Намерение, а не решение: во что обойдётся
  вход, считает ядро в момент старта раздачи (§6 задачи 3).
  """
  @spec request_post(Ecto.UUID.t(), Ecto.UUID.t(), boolean()) :: :ok | {:error, error()}
  def request_post(room_id, user_id, wanted?) when is_boolean(wanted?) do
    with {:ok, pid} <- fetch_room(room_id), do: TableServer.request_post(pid, user_id, wanted?)
  end

  @doc "Сообщение в чат стола. Писать может сидящий, читать — кто угодно."
  @spec chat(Ecto.UUID.t(), Ecto.UUID.t(), term()) :: {:ok, map()} | {:error, error()}
  def chat(room_id, user_id, text) do
    with {:ok, pid} <- fetch_room(room_id), do: TableServer.chat(pid, user_id, text)
  end

  @doc """
  Реакция за столом. Эфемерна: в историю не попадает и при реконнекте
  не переигрывается.
  """
  @spec react(Ecto.UUID.t(), Ecto.UUID.t(), term()) ::
          :ok | {:error, error() | {error(), pos_integer()}}
  def react(room_id, user_id, id) do
    with {:ok, pid} <- fetch_room(room_id), do: TableServer.react(pid, user_id, id)
  end

  @doc """
  Длина окна объявления страддла. Клиент рисует по ней шкалу отсчёта, а
  не хранит собственную копию тайминга.
  """
  @spec straddle_offer_ms() :: pos_integer()
  defdelegate straddle_offer_ms(), to: TableServer

  @doc "Доступный набор реакций в порядке отображения."
  @spec reactions() :: [String.t()]
  def reactions, do: Reactions.ids()

  @doc """
  Ответ на предложение сыграть недостающие улицы дважды.

  Право отвечать проверяет раздача: спрашивают только двоих, дошедших до
  доводки, и только пока окно открыто.
  """
  @spec answer_run_it_twice(Ecto.UUID.t(), Ecto.UUID.t(), boolean()) :: :ok | {:error, error()}
  def answer_run_it_twice(room_id, user_id, accept?) do
    with {:ok, pid} <- fetch_room(room_id),
         do: TableServer.answer_run_it_twice(pid, user_id, accept?)
  end

  @doc """
  Rabbit hunting: показать карты, которые пришли бы, доиграй раздача до
  ривера. Доступно сидящим за столом в паузу после раздачи, законченной
  фолдом; наблюдателю — нет.
  """
  @spec rabbit_hunt(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | {:error, error()}
  def rabbit_hunt(room_id, user_id) do
    with {:ok, pid} <- fetch_room(room_id), do: TableServer.rabbit_hunt(pid, user_id)
  end

  @doc "Показать свои карты по желанию — сбросив или дойдя до вскрытия."
  @spec show_cards(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | {:error, error()}
  def show_cards(room_id, user_id) do
    with {:ok, pid} <- fetch_room(room_id), do: TableServer.show_cards(pid, user_id)
  end

  @doc """
  Ручной запуск стола в комнате без автостарта. Право на команду проверяет
  комната: транспорт лишь передаёт, кто просит.
  """
  @spec start_game(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | {:error, error()}
  def start_game(room_id, user_id) do
    with {:ok, pid} <- fetch_room(room_id), do: TableServer.start_game(pid, user_id)
  end

  @doc """
  Пауза за столом. Раздачу с уже розданными картами игрок обязан доиграть,
  поэтому ответ говорит, началась пауза (`pending: false`) или только принята
  к исполнению (`pending: true`).

  Пауза не бессрочна: просидев `sit_out_timeout_ms`, игрок уходит из-за стола
  с обычным cash-out — кресло за кэш-столом дороже, чем удобство отошедшего.
  """
  @spec sit_out(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, error()}
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
      # `already_seated` здесь того же рода: игрок сидит **в этой** комнате,
      # а просил он не её, а любую комнату лимита. Отказ вместо перехода к
      # следующей делал быстрый вход неработающим для всех, кто уже сидит
      # за самым полным столом лимита, — то есть для мультитейбла.
      {:error, reason}
      when reason in [:seat_taken, :no_seats_available, :room_closing, :already_seated] ->
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
      {:ok, user} -> %{name: user.name, avatar: user.avatar, flair: user.flair, role: user.role}
      {:error, _reason} -> %{}
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
