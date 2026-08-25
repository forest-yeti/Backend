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
  alias BlockPoker.Reactions

  alias BlockPoker.OfcGames
  alias BlockPoker.OfcGames.OfcSetting

  alias BlockPoker.Tables.{
    Blueprint,
    Lobby,
    LobbyQuery,
    RoomState,
    SitAndGoLobby,
    TableRegistry,
    TableServer
  }

  alias BlockPoker.Wallet

  @type entry :: :wait_bb | :post
  @type error :: atom()

  @doc """
  Разбор фильтров и сортировки лобби из сырого payload.

  Отдельно от `lobby_snapshot/1` потому, что разобранный запрос нужен каналу
  дважды: на первичной выдаче и на каждом `lobby_delta` — чтобы не слать
  подписчику лимиты, которые он отфильтровал.
  """
  @spec lobby_query(map() | nil, Blueprint.category()) ::
          {:ok, LobbyQuery.t()} | {:error, :validation_failed}
  def lobby_query(params \\ nil, category \\ :cash),
    do: LobbyQuery.parse(params, category)

  @spec lobby_snapshot(LobbyQuery.t()) :: [map()]
  def lobby_snapshot(query \\ %LobbyQuery{}), do: Lobby.snapshot(Lobby, query)

  @doc """
  Витрина Sit & Go, суженная фильтром по дисциплине.

  Разбор фильтра живёт здесь, а не в канале: что такое «дисциплина» и
  какие они бывают — доменное знание, и транспорту его иметь незачем
  (§3 CLAUDE.md). Незнакомые значения отбрасываются молча: клиент, у
  которого в памяти остался снятый с продажи вид покера, должен увидеть
  остальные, а не ошибку.
  """
  @spec sit_n_go_snapshot(term()) :: [map()]
  def sit_n_go_snapshot(params \\ nil) do
    SitAndGoLobby.snapshot(SitAndGoLobby, parse_game_types(params))
  end

  @doc "Проходит ли шаблон фильтр подписчика — для адресной рассылки обновлений."
  @spec sit_n_go_visible?([atom()], map()) :: boolean()
  def sit_n_go_visible?([], _snapshot), do: true

  def sit_n_go_visible?(game_types, %{setting: setting}),
    do: setting.game_type in game_types

  @doc "Разбор фильтра дисциплин: пустой список означает «все»."
  @spec parse_game_types(term()) :: [atom()]
  def parse_game_types(%{"game_types" => types}) when is_list(types) do
    known = VariantRegistry.ids()

    types
    |> Enum.map(&to_game_type/1)
    |> Enum.filter(&(&1 in known))
    |> Enum.uniq()
  end

  def parse_game_types(_params), do: []

  defp to_game_type(value) when is_binary(value) do
    case VariantRegistry.fetch(value) do
      {:ok, variant} -> variant.id()
      {:error, :unknown_variant} -> nil
    end
  end

  defp to_game_type(_value), do: nil

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

  @doc """
  Фильтры витрины китайского покера. Категории лимита у неё свои: очко и
  большой блайнд — разные величины, и одна шкала на обе врала бы.
  """
  @spec ofc_lobby_filters() :: map()
  def ofc_lobby_filters do
    %{
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
    with {:ok, setting} <- setting_by_code(code),
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

  # Код ищется в обоих разделах витрины: закрытая комната китайского покера
  # заводится тем же кодом и тем же способом, что и кэшевая.
  defp setting_by_code(code) do
    case CashGames.get_by_code(code) do
      {:ok, setting} -> {:ok, setting}
      {:error, :not_found} -> OfcGames.get_by_code(code)
    end
  end

  # У закрытого шаблона комната ровно одна (`Blueprint.room_limit/1`),
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
  @spec buy_in_range(CashGameSetting.t() | OfcSetting.t()) ::
          %{min: pos_integer(), max: pos_integer() | nil}
  def buy_in_range(%CashGameSetting{} = setting) do
    %{
      min: CashGameSetting.min_buy_in_chips(setting),
      max: CashGameSetting.max_buy_in_chips(setting)
    }
  end

  def buy_in_range(%OfcSetting{} = setting) do
    %{min: OfcSetting.min_buy_in_chips(setting), max: OfcSetting.max_buy_in_chips(setting)}
  end

  @spec room_state(Ecto.UUID.t()) :: {:ok, RoomState.t()} | {:error, :not_found}
  def room_state(room_id) do
    with {:ok, pid} <- fetch_room(room_id), do: {:ok, TableServer.state(pid)}
  end

  @doc """
  Разбор руки игрока для окна-калькулятора: что играет и какие есть доезды.

  Отдельный вызов, а не только поле снапшота: окно открывается по кнопке
  и обновляется по улицам, и тянуть ради него весь стол незачем.
  """
  @spec hand_insight(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, BlockPoker.Engine.HandInsight.t() | nil} | {:error, :not_found}
  def hand_insight(room_id, user_id) do
    with {:ok, room} <- room_state(room_id), do: {:ok, RoomState.insight(room, user_id)}
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
  Регистрация в Sit & Go: игрок садится в тот турнир шаблона, который
  сейчас набирается.

  Отдельной сущности «регистрация» нет намеренно — посадка за турнирный
  стол ею и является. Взнос списывает режим (`GameMode.Tournament`),
  стек выдаёт турнир, и обе величины берутся из шаблона, а не от клиента:
  выбирать тут нечего, все входят одинаково.
  """
  @spec register(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, error()}
  def register(setting_id, user_id) do
    with {:ok, room_id} <- SitAndGoLobby.open_room(setting_id),
         {:ok, pid} <- fetch_room(room_id) do
      room = TableServer.state(pid)

      seat_player(pid, room_id, user_id, :first_free, room.setting.starting_stack, :wait_bb)
    end
  end

  @doc """
  Отмена регистрации до старта: взнос возвращается в кошелёк.

  Тот же путь, что и уход из-за стола, — и это не совпадение: право уйти
  решает режим, и в турнире оно есть ровно до первой карты.
  """
  @spec unregister(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, error()}
  def unregister(room_id, user_id), do: leave_seat(room_id, user_id)

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
  Посадки сразу многих игроков — одним обходом комнат.

  Существует ради списка панели администратора: `my_seats/1` спрашивает
  каждую живую комнату, и вызвать её на страницу в полсотни человек
  значило бы опросить пул полсотни раз подряд. Комнаты те же, ответ тот
  же — меняется только то, что обход один.
  """
  @spec seats_of([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => [map()]}
  def seats_of([]), do: %{}

  def seats_of(user_ids) do
    wanted = MapSet.new(user_ids)

    # Реестр, а не пулы лобби: «где сидит игрок» — это все комнаты рума,
    # включая турнирные, которых в витрине нет вовсе. Плюс ответ не
    # зависит от живости лобби: упавший пул не должен уносить с собой
    # список посадок.
    TableRegistry.live_tables()
    |> Enum.flat_map(fn {room_id, _pid} ->
      case room_state(room_id) do
        {:ok, state} -> seats_in(state, wanted)
        {:error, _reason} -> []
      end
    end)
    |> Enum.group_by(& &1.user_id)
  end

  defp seats_in(state, wanted) do
    state
    |> RoomState.seats()
    |> Enum.filter(&(&1.user_id != nil and MapSet.member?(wanted, &1.user_id)))
    |> Enum.map(fn seat ->
      %{
        user_id: seat.user_id,
        room_id: state.room_id,
        setting_id: state.setting.id,
        # Валюта комнаты: без неё стек — просто число, а масштаб у него
        # разный (центы у `main`, целые фишки у `play_money`).
        currency: state.setting.currency,
        seat: seat.number,
        stack: seat.stack,
        status: seat.status
      }
    end)
  end

  @doc """
  Выплата призов турнира: единственное место, где приз доходит до кошелька.

  Идёт после расчёта, вне процесса стола: транзакция в кошелёк не должна
  задерживать комнату. Ключ идемпотентности собирается из комнаты и места,
  поэтому повтор — ретрай после обрыва, падение процесса — не выплатит
  приз дважды: UNIQUE журнала это отвергнет.

  Место вне призовой зоны записи не порождает (`Wallet.award_prize/5`).
  """
  @spec pay_out(RoomState.t(), [map()]) :: :ok
  def pay_out(%RoomState{} = room, results) do
    Enum.each(results, fn result ->
      Wallet.award_prize(
        result.user_id,
        room.setting.currency,
        result.amount,
        "sng_prize:#{room.room_id}:#{result.place}",
        ref_id: room.room_id
      )
    end)
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
      room = TableServer.state(pid)

      case room.mode.return_chips(room, user_id, stack, ref) do
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
  Докупка. Разрешена в любой момент, независимо от текущего стека; верх
  ограничен `max_buy_in`. Во время раздачи фишки на стол не падают —
  это меняло бы эффективный стек посреди торговли, — но и отказа игрок
  не получает: деньги списываются сразу, а фишки ложатся на стол в начале
  следующей раздачи (`{:ok, %{queued: true}}`). Ловить паузу между раздачами
  игрок не должен: заказать докупку и играть дальше — одно действие.

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
         {:ok, ref, replaced} <- TableServer.begin_add_chips(pid, user_id, amount),
         room = TableServer.state(pid),
         :ok <- take_buy_in(pid, room, user_id, amount, ref, replaced) do
      refund_replaced(room, user_id, replaced)
      commit_add_chips(pid, room_id, user_id, amount, ref)
    end
  end

  # Новая заявка вытеснила старую отложенную: её деньги возвращаются в
  # кошелёк. Возврат делается после успешного списания новой суммы — так
  # игрок не может, меняя заявку туда-обратно, оказаться с деньгами и на
  # столе, и в кошельке.
  defp refund_replaced(_room, _user_id, nil), do: :ok

  defp refund_replaced(room, user_id, %{ref: ref, amount: amount}) do
    return_lost_chips(room, user_id, amount, "replaced:#{ref}")
  end

  # Списание не прошло: ключ надо снять с места, иначе следующая попытка
  # упрётся в «предыдущая докупка ещё не завершена» при пустом кошельке.
  defp take_buy_in(pid, room, user_id, amount, ref, replaced) do
    case room.mode.take_buy_in(room, user_id, amount, ref) do
      :ok ->
        :ok

      {:error, reason} ->
        TableServer.abort_add_chips(pid, user_id, ref)

        # Вытесненная заявка уже снята со стола: её деньги возвращаются даже
        # тогда, когда новая не прошла, — иначе они пропадут между двумя.
        refund_replaced(room, user_id, replaced)
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
        {:ok, %{room_id: room_id, seat: seat.number, stack: seat.stack, queued: 0}}

      # Стол в раздаче: деньги списаны, фишки ждут её конца. Для игрока это
      # успех — с той разницей, что стек вырастет не сейчас.
      {:queued, seat, queued} ->
        {:ok, %{room_id: room_id, seat: seat.number, stack: seat.stack, queued: queued}}

      # Повтор по уже отработавшему ключу: фишки на столе с первого раза,
      # второго списания не было (кошелёк снял дубль по `idempotency_key`),
      # и возвращать нечего. Игроку это неотличимо от успеха — им и является.
      {:already_credited, seat} ->
        {:ok, %{room_id: room_id, seat: seat.number, stack: seat.stack, queued: 0}}

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
    case room.mode.return_chips(room, user_id, amount, ref) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "докупка #{ref}: #{amount} списано, но не зачислено и не возвращено (#{inspect(reason)})"
        )

        :error
    end
  end

  @doc """
  Отменить отложенную докупку до того, как она легла на стол. Деньги
  возвращаются в кошелёк; отменять уже зачисленную докупку нечего —
  это обычный уход из-за стола.
  """
  @spec cancel_add_chips(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, error()}
  def cancel_add_chips(room_id, user_id) do
    with {:ok, pid} <- fetch_room(room_id),
         {:ok, ref, amount} <- TableServer.cancel_add_chips(pid, user_id) do
      room = TableServer.state(pid)
      return_lost_chips(room, user_id, amount, "cancel:#{ref}")
      {:ok, %{room_id: room_id, returned: amount}}
    end
  end

  @doc """
  Вернуть фишки в кошелёк. Публична ради комнаты: урезанный остаток
  отложенной докупки возвращается из процесса стола фоновой задачей.
  """
  @spec return_chips(map(), Ecto.UUID.t(), pos_integer(), String.t()) :: :ok | :error
  def return_chips(room, user_id, amount, ref), do: return_lost_chips(room, user_id, amount, ref)

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
  @spec show_cards(Ecto.UUID.t(), Ecto.UUID.t(), [non_neg_integer()] | :all) ::
          :ok | {:error, error()}
  def show_cards(room_id, user_id, cards \\ :all) do
    with {:ok, pid} <- fetch_room(room_id), do: TableServer.show_cards(pid, user_id, cards)
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

      case room.mode.take_buy_in(room, user_id, buy_in, reservation_id) do
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
        room.mode.return_chips(room, user_id, buy_in, reservation_id)
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
