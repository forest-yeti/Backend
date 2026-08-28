defmodule BlockPoker.Tournaments do
  @moduledoc """
  Контекст турниров: шаблоны, расписание, инстансы, вход и деньги.

  Наружу отдаёт **готовые к игре** значения: расписание уровней в виде,
  который понимает `Engine.BlindSchedule`, сетку выплат в виде, который
  понимает `Engine.TournamentPayout`. Транспорт и процессы работают с
  ними, а не со схемами Ecto.

  ## Что здесь, а не в процессе

  Всё, что переживает рестарт и всё, что связано с деньгами: список
  участников, счётчики входов, фонд, места и записи ledger. Ход игры —
  не здесь: уровнем, рассадкой и порядком вылетов владеет
  `TournamentServer`, а сюда он приносит уже случившиеся факты.

  ## Почему регистрация — одна транзакция с блокировкой строки

  Взнос и комиссия обязаны списаться вместе: денег хватает на взнос, но
  не на комиссию — отказ целиком, а не «наполовину зарегистрирован».
  Счётчики входов при этом проверяются под `SELECT ... FOR UPDATE` по
  строке инстанса: без блокировки два одновременных запроса на последнее
  место оба увидят свободный потолок и оба пройдут.

  Двойной клик гасится не проверкой в коде, а уникальным индексом:
  `(tournament_id, user_id, entry_number)` в `tournament_entries` и
  `idempotency_key` в `wallet_entries`.
  """

  require Logger

  import Ecto.Query

  alias BlockPoker.Engine.{BlindSchedule, Bounty, TournamentPayout}
  alias BlockPoker.History
  alias BlockPoker.Engine.Elimination
  alias BlockPoker.Repo
  alias BlockPoker.Tables.LobbyQuery
  alias BlockPoker.Tickets
  alias BlockPoker.Tickets.UserTicket

  alias BlockPoker.Tournaments.{
    BlindLevel,
    Entry,
    LobbyEntry,
    PayoutRow,
    Schedule,
    SeatSnapshot,
    Tournament,
    TournamentServer,
    TournamentSetting,
    TournamentSupervisor
  }

  alias BlockPoker.Wallet
  alias Ecto.Multi
  alias Phoenix.PubSub

  @pubsub BlockPoker.PubSub

  # Сколько аддонов положено одному входу. Константа, а не поле шаблона:
  # см. `addon/2` — второй аддон превращает точку структуры в докупку без
  # потолка, и настройкой такое не делают.
  @addons_per_entry 1

  @typedoc "Фильтр витрины шаблонов."
  @type filter :: [game_types: [atom()], currency: atom(), enabled: boolean()]

  # --- Шаблоны -------------------------------------------------------------

  @doc "Топик, на котором инстанс рассказывает о себе."
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(tournament_id), do: "tournament_events:#{tournament_id}"

  @doc "Топик витрины турниров."
  @spec lobby_topic() :: String.t()
  def lobby_topic, do: "tournament_lobby_events"

  @doc "Шаблоны для витрины, в том порядке, в каком их показывает лобби."
  @spec list_settings(filter()) :: [TournamentSetting.t()]
  def list_settings(filter \\ []) do
    TournamentSetting
    |> filter_enabled(Keyword.get(filter, :enabled, true))
    |> filter_game_types(Keyword.get(filter, :game_types, []))
    |> filter_currency(Keyword.get(filter, :currency))
    |> preload([:blind_levels, :schedules, payout_rows: :ticket])
    |> Repo.all()
    # Порядок задаётся в Elixir, а не в SQL: разряд валюты — доменное
    # правило, а не алфавит.
    |> Enum.sort_by(&TournamentSetting.sort_key/1)
  end

  @spec get_setting(Ecto.UUID.t()) :: {:ok, TournamentSetting.t()} | {:error, :not_found}
  def get_setting(id) do
    TournamentSetting
    |> preload([:blind_levels, :schedules, payout_rows: :ticket])
    |> Repo.get(id)
    |> case do
      nil -> {:error, :not_found}
      setting -> {:ok, setting}
    end
  end

  @doc "Расписание уровней шаблона в виде, который читает `Engine.BlindSchedule`."
  @spec blind_schedule(TournamentSetting.t()) :: [BlindSchedule.level()]
  def blind_schedule(%TournamentSetting{blind_levels: levels}) when is_list(levels) do
    levels |> Enum.sort_by(& &1.level) |> Enum.map(&BlindLevel.to_schedule/1)
  end

  @doc """
  Флаги уровня: можно ли на нём войти заново и взять аддон.

  Отдельно от `blind_schedule/1`, потому что `Engine.BlindSchedule` про
  номиналы и ничего не знает про регистрацию — и знать не должен: это
  расписание блайндов, а не правила входа.
  """
  @spec level_flags(TournamentSetting.t()) :: %{
          pos_integer() => %{rebuy_allowed: boolean(), addon_allowed: boolean()}
        }
  def level_flags(%TournamentSetting{blind_levels: levels}) when is_list(levels) do
    Map.new(levels, fn level ->
      {level.level, %{rebuy_allowed: level.rebuy_allowed, addon_allowed: level.addon_allowed}}
    end)
  end

  @doc "Сетка выплат шаблона в виде, который читает `Engine.TournamentPayout`."
  @spec payout_grid(TournamentSetting.t()) :: [TournamentPayout.row()]
  def payout_grid(%TournamentSetting{payout_rows: rows}) when is_list(rows) do
    Enum.map(rows, &PayoutRow.to_row/1)
  end

  @doc """
  Флаги уровней **инстанса** — из его снапшота, по той же причине, по
  которой из снапшота берётся сетка выплат (`snapshot_payout_grid/1`):
  правка шаблона посреди турнира не должна ни открыть ре-энтри заново,
  ни передвинуть уровень аддона под ногами у играющих.

  Пустая карта — снапшота ещё нет; для клиента это «флагов не знаем»,
  а не «всё запрещено», и рисуется отсутствием пометок.
  """
  @spec snapshot_level_flags(map() | nil) :: %{
          pos_integer() => %{rebuy_allowed: boolean(), addon_allowed: boolean()}
        }
  def snapshot_level_flags(nil), do: %{}

  def snapshot_level_flags(snapshot) when is_map(snapshot) do
    Map.new(snapshot["levels"] || [], fn level ->
      {level["level"],
       %{
         rebuy_allowed: level["rebuy_allowed"] == true,
         addon_allowed: level["addon_allowed"] == true
       }}
    end)
  end

  @doc """
  Сетка выплат **инстанса** — из его снапшота, а не из живого шаблона.

  Снапшот для того и снят при открытии регистрации: правка
  `tournament_payouts` посреди турнира не должна сдвигать ни призовую
  границу под ногами у играющих, ни сумму, уже объявленную вылетевшему.
  Поэтому всё, что считается по **идущему** инстансу, берёт сетку здесь;
  `payout_grid/1` остаётся для шаблона, у которого инстанса ещё нет.

  Пустой список — снапшота ещё нет (инстанс до открытия регистрации).
  `Engine.TournamentPayout.compute/4` на нём вернёт пустые выплаты, а не
  упадёт: «сетки пока нет» — это состояние, а не ошибка.
  """
  @spec snapshot_payout_grid(map() | nil) :: [TournamentPayout.row()]
  def snapshot_payout_grid(nil), do: []

  def snapshot_payout_grid(snapshot) when is_map(snapshot) do
    # Ключи строковые: снапшот — это JSON из БД, а не структура Elixir
    # (см. `build_snapshot/1`).
    Enum.map(snapshot["payouts"] || [], fn row ->
      %{
        entries_from: row["entries_from"],
        entries_to: row["entries_to"],
        place_from: row["place_from"],
        place_to: row["place_to"],
        share_ppm: row["share_ppm"],
        ticket_id: row["ticket_id"],
        ticket_value: row["ticket_value"]
      }
    end)
  end

  @doc """
  Создаёт шаблон вместе с уровнями, сеткой выплат и расписанием — одной
  транзакцией.

  Целиком или никак: шаблон без уровней не запускается, а без сетки не
  может закончиться выплатой. Половина строк в БД была бы не «частично
  готовым турниром», а сломанным.

  Аудит идёт **до коммита**: набор, не прошедший проверку, откатывается.
  """
  @spec create_setting(map(), [map()], [map()], [map()]) ::
          {:ok, TournamentSetting.t()} | {:error, atom() | Ecto.Changeset.t()}
  def create_setting(attrs, levels, payouts, schedules \\ []) do
    Multi.new()
    |> Multi.insert(:setting, TournamentSetting.changeset(%TournamentSetting{}, attrs))
    |> Multi.run(:levels, &insert_children(&1, &2.setting, levels, BlindLevel))
    |> Multi.run(:payouts, &insert_children(&1, &2.setting, payouts, PayoutRow))
    |> Multi.run(:schedules, &insert_children(&1, &2.setting, schedules, Schedule))
    |> Multi.run(:audit, fn _repo, changes ->
      audit_parts(changes.setting, changes.levels, changes.payouts)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{setting: setting}} -> get_setting(setting.id)
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Сносит всю турнирную сетку: шаблоны, их уровни, выплаты, расписание
  и поднятые по расписанию инстансы.

  Существует ради `mix tournament.seed --reset`. Инстансы уезжают вместе
  с шаблонами не по небрежности, а потому что турнир без шаблона
  недоигрываем: структуру и сетку выплат он читает из него.
  """
  @spec delete_all_settings() :: %{settings: non_neg_integer(), tournaments: non_neg_integer()}
  def delete_all_settings do
    {tournaments, _returned} = Repo.delete_all(Tournament)
    {settings, _returned} = Repo.delete_all(TournamentSetting)

    %{settings: settings, tournaments: tournaments}
  end

  @doc """
  Проверка шаблона целиком — то, что не выразить ни constraint'ом, ни
  changeset'ом одной строки, потому что это свойства **набора**.

  Проверяются уровни (`BlindLevel.validate_set/2`) и сетка выплат
  (`Engine.TournamentPayout.validate/3`). Обе проверки существуют ради
  одного: турнир, который нельзя доиграть или нечем закончить, не должен
  доживать до вечера пятницы.
  """
  @spec audit(TournamentSetting.t()) :: :ok | {:error, atom()}
  def audit(%TournamentSetting{} = setting) do
    audit_parts(setting, setting.blind_levels, setting.payout_rows)
    |> case do
      {:ok, :audited} -> :ok
      error -> error
    end
  end

  defp audit_parts(setting, levels, payouts) do
    with :ok <- BlindLevel.validate_set(levels, setting.addon_cost),
         :ok <-
           payouts
           |> Enum.map(&PayoutRow.to_row/1)
           |> TournamentPayout.validate(setting.min_players, setting.max_players) do
      {:ok, :audited}
    end
  end

  # --- Инстансы ------------------------------------------------------------

  @doc """
  Витрина турниров: строки лобби, отфильтрованные и отсортированные.

  Персональные признаки («мои», «куда пускает билет») считаются здесь,
  а не в канале: канал знает, **кто** спрашивает, но не знает, что
  означает «мой турнир» (§3 CLAUDE.md).
  """
  @spec lobby(LobbyQuery.t(), Ecto.UUID.t() | nil, DateTime.t()) :: [LobbyEntry.t()]
  def lobby(%LobbyQuery{} = query, user_id \\ nil, now \\ DateTime.utc_now()) do
    tournaments = list_upcoming(now)

    registered = registered_ids(tournaments, user_id)
    tickets = ticket_setting_ids(user_id, now)

    tournaments
    |> Enum.map(fn tournament ->
      LobbyEntry.build(tournament,
        now: now,
        registered: tournament.id in registered,
        has_ticket: tournament.tournament_setting_id in tickets
      )
    end)
    |> then(&LobbyQuery.apply(query, &1))
  end

  # Одним запросом на всю витрину, а не по строке: витрина из трёхсот
  # турниров иначе стоила бы трёхсот запросов на каждое открытие лобби.
  defp registered_ids(_tournaments, nil), do: MapSet.new()

  defp registered_ids(tournaments, user_id) do
    ids = Enum.map(tournaments, & &1.id)

    Entry
    |> where([e], e.user_id == ^user_id and e.tournament_id in ^ids)
    |> where([e], e.status in [:registered, :playing])
    |> select([e], e.tournament_id)
    |> Repo.all()
    |> MapSet.new()
  end

  defp ticket_setting_ids(nil, _now), do: MapSet.new()

  defp ticket_setting_ids(user_id, now) do
    user_id
    |> Tickets.list_active(now)
    |> MapSet.new(& &1.ticket.tournament_setting_id)
  end

  @doc """
  Карточка турнира: состав, структура, сетка выплат при текущей явке и
  чипсчёт с пагинацией.

  Отдельный запрос, а не подписка: лидерборд, обновляющийся на каждом
  вылете, — это квадратичный трафик из лобби. Игрок смотрит его раз в
  несколько минут, а вылеты идут каждые несколько секунд.
  """
  @spec card(Ecto.UUID.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def card(tournament_id, opts \\ []) do
    with {:ok, tournament} <- get_tournament(tournament_id) do
      limit = opts |> Keyword.get(:limit, 50) |> min(200)
      offset = Keyword.get(opts, :offset, 0)

      {:ok,
       %{
         entry: LobbyEntry.build(tournament, now: Keyword.get(opts, :now, DateTime.utc_now())),
         levels: blind_schedule(tournament.setting),
         level_flags: level_flags(tournament.setting),
         payouts: card_payouts(tournament),
         chip_counts: chip_counts(tournament, limit, offset, Keyword.get(opts, :user_id))
       }}
    end
  end

  # Сетка карточки считается по **живому** фонду, а не по
  # `tournament.prize_pool`: он заполняется только при закрытии поздней
  # регистрации, а до того равен нулю — и карточка весь час записи
  # показывала бы «Призовой фонд» с нулями на каждом месте.
  #
  # Сетка берётся из снапшота инстанса, пока он есть: турнир уже идёт, и
  # правка шаблона не должна сдвигать объявленные суммы. У анонса
  # снапшота ещё нет — там читается шаблон.
  defp card_payouts(tournament) do
    case get_setting(tournament.tournament_setting_id) do
      {:ok, setting} ->
        %{prize_pool: pool} = TournamentPayout.pool(collected(tournament), setting.guarantee)

        grid =
          case snapshot_payout_grid(tournament.snapshot) do
            [] -> payout_grid(setting)
            rows -> rows
          end

        TournamentPayout.compute(
          grid,
          tournament.entries_count,
          tournament.players_count,
          max(tournament.prize_pool, pool)
        )

      {:error, _reason} ->
        []
    end
  end

  # Чипсчёт с пагинацией: страницами, а не целиком, потому что при
  # трёхстах участниках целиком — это триста строк на каждое открытие.
  #
  # Стек и стол в БД не лежат: они живут в процессе турнира и переживают
  # его только снимком рассадки. Поэтому у идущего турнира страница
  # собирается в памяти — иначе порядок «по стеку» пришлось бы считать
  # запросом к тому, чего в таблице нет.
  defp chip_counts(tournament, limit, offset, user_id) do
    query =
      from(e in Entry, as: :entry)
      |> where([e], e.tournament_id == ^tournament.id)
      |> where([e], e.status != :refunded)
      |> reject_superseded()
      |> preload(:user)

    total = Repo.aggregate(query, :count)

    {rows, me} =
      case live_players(tournament.id) do
        nil ->
          # Турнир не поднят: стеков нет, ранга по фишкам не существует —
          # искать в этом списке «себя с местом» нечего.
          {query |> page(limit, offset) |> Repo.all() |> Enum.map(&row(&1, nil)), nil}

        players ->
          ranked = query |> Repo.all() |> rank_by_stack(players)

          {Enum.slice(ranked, offset, limit), mine(ranked, user_id)}
      end

    %{entries: rows, total: total, limit: limit, offset: offset, me: me}
  end

  # Своя строка с **абсолютным** рангом, вне зависимости от страницы.
  # Нужна тем, кто смотрит только верх списка: игроку сотому по стеку
  # верхняя десятка не говорит ничего, пока рядом с ней нет его самого,
  # а листать за собой по страницам ради одной строки — работа, которую
  # клиент делать не должен.
  defp mine(_ranked, nil), do: nil

  defp mine(ranked, user_id) do
    ranked
    |> Enum.with_index(1)
    |> Enum.find_value(fn {row, rank} ->
      if row.user_id == user_id and row.status == :playing, do: %{row: row, rank: rank}
    end)
  end

  # Вход, отменённый ре-энтри, из чипсчёта убирается: вылета не было,
  # места ему не присвоено, а игрок продолжает играть новым входом.
  # Оставленный, он висел бы вторым «я» с нулевым стеком — тем самым
  # дублем, которого в списке игроков быть не должно. Вылет с местом
  # (`place`) при этом остаётся: это результат, а не отменённая запись.
  defp reject_superseded(query) do
    superseded =
      from(other in Entry,
        where:
          other.tournament_id == parent_as(:entry).tournament_id and
            other.user_id == parent_as(:entry).user_id and
            other.entry_number > parent_as(:entry).entry_number and
            other.status != :refunded
      )

    where(query, [e], e.status != :busted or not is_nil(e.place) or not exists(superseded))
  end

  defp page(query, limit, offset) do
    query
    |> order_by([e], desc: e.status == :playing, asc: e.place, asc: e.entry_number)
    |> limit(^limit)
    |> offset(^offset)
  end

  # `nil` — процесс турнира не поднят: стеков ещё (или уже) нет, и
  # выдумывать их клиенту нечем.
  defp live_players(tournament_id) do
    case TournamentServer.whereis(tournament_id) do
      nil -> nil
      pid -> Map.new(TournamentServer.players(pid), &{&1.entry_id, &1})
    end
  end

  # Живой первым и с большим стеком выше: ранг в чипсчёте — это место по
  # фишкам, а не порядок регистрации. Вылетевшие уходят вниз в порядке
  # занятых мест.
  defp rank_by_stack(entries, players) do
    entries
    |> Enum.map(fn entry -> {entry, Map.get(players, entry.id)} end)
    |> Enum.sort_by(fn {entry, player} ->
      {entry.status != :playing, -stack_of(player), entry.place || 0, entry.entry_number}
    end)
    |> Enum.map(fn {entry, player} -> row(entry, player) end)
  end

  # Строка чипсчёта — обычная карта, а не запись: стек и стол в схеме
  # входа не живут, и подмешивать их в структуру значило бы получить
  # запись, которой в БД не существует.
  defp row(entry, player) do
    %{
      entry_id: entry.id,
      user_id: entry.user_id,
      name: entry.user && entry.user.name,
      entry_number: entry.entry_number,
      status: entry.status,
      bounty: entry.bounty,
      place: entry.place,
      prize: entry.prize,
      stack: stack_of(player),
      # `nil` — турнир ещё не начался либо вход уже вылетел: открывать
      # нечего, и клиент гасит кнопку «Открыть стол».
      table_id: player && player.table_id,
      seat: player && player.seat
    }
  end

  defp stack_of(nil), do: 0
  defp stack_of(player), do: player.stack || 0

  @spec get_tournament(Ecto.UUID.t()) :: {:ok, Tournament.t()} | {:error, :not_found}
  def get_tournament(id) do
    Tournament
    |> preload(setting: [:blind_levels, payout_rows: :ticket])
    |> Repo.get(id)
    |> case do
      nil -> {:error, :not_found}
      tournament -> {:ok, tournament}
    end
  end

  @doc """
  Инстансы, которые витрина показывает: анонсированные, набирающие и
  идущие.

  Законченные и отменённые в общий список не идут — игрок выбирает,
  во что успевает, а не листает архив.
  """
  @spec list_upcoming(DateTime.t()) :: [Tournament.t()]
  def list_upcoming(_now \\ DateTime.utc_now()) do
    Tournament
    |> where([t], t.status in [:announced, :registering, :running, :late_reg_closed, :finishing])
    |> preload(setting: [:blind_levels, payout_rows: :ticket])
    |> order_by([t], asc: t.starts_at, asc: t.id)
    |> Repo.all()
  end

  @doc """
  Создаёт инстанс расписания на конкретный момент, если его ещё нет.

  Идемпотентность держит уникальный индекс `(schedule_id, starts_at)`:
  тик планировщика не должен зависеть от того, сколько раз он сработал.
  Поэтому нарушение UNIQUE здесь — не ошибка, а «уже создан».
  """
  @spec ensure_instance(Schedule.t(), DateTime.t()) ::
          {:ok, Tournament.t()} | {:already_exists, Tournament.t()} | {:error, term()}
  def ensure_instance(%Schedule{} = schedule, %DateTime{} = starts_at) do
    attrs = %{
      tournament_setting_id: schedule.tournament_setting_id,
      schedule_id: schedule.id,
      starts_at: starts_at,
      status: :announced
    }

    %Tournament{}
    |> Tournament.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, tournament} ->
        {:ok, tournament}

      {:error, changeset} ->
        if duplicate?(changeset) do
          {:already_exists,
           Repo.get_by!(Tournament, schedule_id: schedule.id, starts_at: starts_at)}
        else
          {:error, changeset}
        end
    end
  end

  @doc """
  Открывает регистрацию: `announced → registering`.

  Здесь же снимается **снапшот настроек**. Дальше инстанс не читает
  шаблон вовсе: правка структуры в БД не должна поднимать блайнды посреди
  идущего турнира, а турнир идёт часами, и вероятность правки во время
  игры реальна.
  """
  @spec open_registration(Tournament.t()) :: {:ok, Tournament.t()} | {:error, term()}
  def open_registration(%Tournament{status: :announced} = tournament) do
    with {:ok, setting} <- get_setting(tournament.tournament_setting_id) do
      tournament
      |> Tournament.changeset(%{status: :registering, snapshot: build_snapshot(setting)})
      |> Repo.update()
      |> announce()
    end
  end

  def open_registration(%Tournament{}), do: {:error, :invalid_status}

  @doc """
  Снапшот настроек инстанса: уровни, сетка, цены и тайминги на момент
  открытия регистрации.

  Ключи строковые, потому что это JSON в БД, а не структура Elixir:
  атомы, восстановленные из чужого JSON, — источник утечки таблицы атомов.
  """
  @spec build_snapshot(TournamentSetting.t()) :: map()
  def build_snapshot(%TournamentSetting{} = setting) do
    %{
      "game_type" => Atom.to_string(setting.game_type),
      "currency" => Atom.to_string(setting.currency),
      "buy_in" => setting.buy_in,
      "entry_fee" => setting.entry_fee,
      "starting_stack" => setting.starting_stack,
      "table_size" => setting.table_size,
      "min_players" => setting.min_players,
      "max_players" => setting.max_players,
      "max_entries" => setting.max_entries,
      "rebuy_allowed" => setting.rebuy_allowed,
      "rebuy_cost" => TournamentSetting.reentry_price(setting),
      "rebuy_stack" => TournamentSetting.reentry_stack(setting),
      "max_rebuys" => setting.max_rebuys,
      "addon_cost" => setting.addon_cost,
      "addon_stack" => setting.addon_stack,
      "guarantee" => setting.guarantee,
      "bounty_part" => setting.bounty_part,
      "bounty_progressive" => setting.bounty_progressive,
      "bounty_split_ppm" => setting.bounty_split_ppm,
      "levels" =>
        Enum.map(
          setting.blind_levels,
          &(Map.take(BlindLevel.to_schedule(&1), [
              :level,
              :small_blind,
              :big_blind,
              :ante,
              :duration_seconds
            ])
            |> stringify()
            |> Map.merge(%{
              "rebuy_allowed" => &1.rebuy_allowed,
              "addon_allowed" => &1.addon_allowed
            }))
        ),
      "payouts" => Enum.map(setting.payout_rows, &(&1 |> PayoutRow.to_row() |> stringify()))
    }
  end

  # --- Регистрация ---------------------------------------------------------

  @doc """
  Регистрация в турнир — деньгами или билетом.

  `opts[:pay_with]` — `:money` (по умолчанию) либо `:ticket`. Ре-энтри и
  аддон билетом не оплачиваются: билет пускает в турнир, а не докупает
  фишки.

  Одна транзакция: строка инстанса блокируется, проверяются потолки,
  списываются взнос и комиссия, вставляется вход, обновляются счётчики.
  Отказ на любом шаге откатывает всё.
  """
  @spec register(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Entry.t()} | {:error, atom() | Ecto.Changeset.t()}
  def register(tournament_id, user_id, opts \\ []) do
    enter(tournament_id, user_id, :entry, opts)
  end

  @doc """
  Повторный вход после вылета.

  **Только после вылета.** Игрок с фишками войти заново не может — это не
  докупка, и второго стека ему не положено. Классический «ребай при
  коротком стеке» в первой версии не реализуется: он требует отдельного
  правила о двух стеках одного игрока и не нужен там, где есть ре-энтри.

  В баунти-турнире повторный вход несёт **новую** голову: прежняя уже
  выплачена убийце и не отбирается.
  """
  @spec reenter(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Entry.t()} | {:error, atom() | Ecto.Changeset.t()}
  def reenter(tournament_id, user_id) do
    enter(tournament_id, user_id, :reentry, [])
  end

  defp enter(tournament_id, user_id, kind, opts) do
    Multi.new()
    |> Multi.run(:tournament, fn repo, _changes -> lock_tournament(repo, tournament_id) end)
    |> Multi.run(:setting, fn _repo, %{tournament: tournament} ->
      get_setting(tournament.tournament_setting_id)
    end)
    |> Multi.run(:slot, fn repo, changes ->
      check_slot(repo, changes.tournament, changes.setting, user_id, kind)
    end)
    |> Multi.run(:payment, fn repo, changes ->
      take_payment(repo, changes, user_id, kind, Keyword.get(opts, :pay_with, :money))
    end)
    |> Multi.run(:entry, fn repo, changes -> insert_entry(repo, changes, user_id, kind) end)
    |> Multi.run(:counters, fn repo, changes -> bump_counters(repo, changes, kind) end)
    |> Repo.transaction()
    |> case do
      {:ok, %{entry: entry, payment: payment}} ->
        Enum.each(payment.entries, &Wallet.publish(user_id, &1))
        ensure_server(entry.tournament_id)

        # Ре-энтри сажает сам турнир: он и позвал `enter/4`, и звать его
        # отсюда значило бы вызов процесса из него самого.
        if kind == :entry, do: seat_if_running(entry)
        announce_tournament(entry.tournament_id)
        {:ok, entry}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # Строка инстанса блокируется на всё время транзакции: без этого два
  # одновременных запроса на последнее место оба увидят свободный потолок.
  defp lock_tournament(repo, tournament_id) do
    query = from t in Tournament, where: t.id == ^tournament_id, lock: "FOR UPDATE"

    case repo.one(query) do
      nil -> {:error, :not_found}
      tournament -> {:ok, tournament}
    end
  end

  # Единственное место, где решается «пустят ли»: и потолки, и статус,
  # и лимит игрока. Канал этого не знает и знать не должен (§3 CLAUDE.md).
  defp check_slot(repo, tournament, setting, user_id, kind) do
    # Возвращённые входы (разрегистрация, отмена) остаются в таблице
    # и различаются от живых. Их роль в трёх счётах разная, и смешивать
    # их нельзя:
    #
    #   * **номер входа** считается по всем записям, включая возвращённые.
    #     Из номера строится ключ идемпотентности списания, и переиспользовать
    #     номер значило бы переиспользовать ключ: кошелёк принял бы повторную
    #     регистрацию за ретрай первой и не списал бы денег вовсе;
    #   * **лимит ре-энтри** и **число людей** считаются только по живым:
    #     разрегистрировавшийся не потратил попытку и не занимает места.
    all_entries = user_entries(repo, tournament.id, user_id)
    entries = Enum.reject(all_entries, &(&1.status == :refunded))
    seated? = Enum.any?(entries, &Entry.seated?/1)

    max_entries = setting.max_entries
    max_rebuys = setting.max_rebuys

    cond do
      not Tournament.registering?(tournament) ->
        {:error, registration_error(tournament)}

      late_reg_expired?(tournament) ->
        {:error, :registration_closed}

      is_integer(max_entries) and tournament.entries_count >= max_entries ->
        {:error, :tournament_full}

      kind == :entry and seated? ->
        {:error, :already_registered}

      # Ре-энтри с живыми фишками — не докупка. Игрок уже в турнире,
      # и второй стек ему не положен.
      kind == :reentry and seated? ->
        {:error, :already_registered}

      kind == :reentry and not setting.rebuy_allowed ->
        {:error, :reentry_not_allowed}

      kind == :reentry and is_integer(max_rebuys) and length(entries) > max_rebuys ->
        {:error, :rebuy_limit_reached}

      # Потолок одновременно играющих считается по **людям**: 70 входов
      # пятидесяти человек упираются в потолок пятьюдесятью, а не семьюдесятью.
      kind == :entry and tournament.players_count >= setting.max_players ->
        {:error, :tournament_full}

      true ->
        {:ok, %{entry_number: length(all_entries) + 1, new_player?: entries == []}}
    end
  end

  defp registration_error(%Tournament{status: :cancelled}), do: :tournament_cancelled
  defp registration_error(%Tournament{status: :announced}), do: :registration_closed
  defp registration_error(%Tournament{}), do: :tournament_started

  # После старта вход живёт по флагу уровня, а не по статусу: `late_reg_until`
  # проставлен на старте как конец последнего ребайного уровня.
  defp late_reg_expired?(%Tournament{status: :running, late_reg_until: nil}), do: false

  defp late_reg_expired?(%Tournament{status: :running, late_reg_until: until}) do
    DateTime.compare(DateTime.utc_now(), until) == :gt
  end

  defp late_reg_expired?(%Tournament{}), do: false

  defp user_entries(repo, tournament_id, user_id) do
    Entry
    |> where([e], e.tournament_id == ^tournament_id and e.user_id == ^user_id)
    |> order_by([e], asc: e.entry_number)
    |> repo.all()
  end

  # --- Деньги входа --------------------------------------------------------

  defp take_payment(repo, changes, user_id, kind, pay_with) do
    %{tournament: tournament, setting: setting, slot: slot} = changes

    price = price_of(setting, kind)

    cond do
      # Фриролл: записей в ledger на входе нет вовсе. Это законный,
      # а не вырожденный случай.
      price.total == 0 ->
        {:ok, %{entries: [], ticket: nil}}

      pay_with == :ticket and kind == :entry ->
        pay_with_ticket(repo, tournament, setting, user_id)

      pay_with == :ticket ->
        {:error, :ticket_not_accepted}

      true ->
        pay_with_money(repo, tournament, setting, user_id, kind, price, slot)
    end
  end

  # Взнос и комиссия — две записи, но одна транзакция: «денег хватает на
  # взнос, но не на комиссию» означает отказ целиком, а не половину
  # регистрации.
  defp pay_with_money(repo, tournament, setting, user_id, kind, price, slot) do
    with {:ok, wallet} <- Wallet.get_wallet(user_id, setting.currency) do
      reference = reference_of(kind, tournament.id, user_id, slot.entry_number)

      Multi.new()
      |> Wallet.record_entry(:stake, %{
        wallet_id: wallet.id,
        amount: -price.stake,
        type: stake_type(kind),
        ref_id: tournament.id,
        idempotency_key: reference
      })
      |> maybe_fee(wallet.id, price.fee, tournament.id, reference)
      |> repo.transaction()
      |> case do
        {:ok, changes} ->
          {:ok, %{entries: Enum.map(Map.values(changes), & &1), ticket: nil}}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  # Нулевая комиссия записи не порождает: операция на ноль — не операция.
  defp maybe_fee(multi, _wallet_id, 0, _ref_id, _reference), do: multi

  defp maybe_fee(multi, wallet_id, fee, ref_id, reference) do
    Wallet.record_entry(multi, :fee, %{
      wallet_id: wallet_id,
      amount: -fee,
      type: :tournament_fee,
      ref_id: ref_id,
      idempotency_key: reference <> ":fee"
    })
  end

  # Регистрация билетом: билет `active → used`, в ledger ничего. Взнос уже
  # оплачен саттелитом, а в `collected` вход засчитывается по номиналу.
  defp pay_with_ticket(repo, tournament, setting, user_id) do
    with {:ok, user_ticket} <- find_ticket(user_id, setting.id) do
      Multi.new()
      |> Tickets.redeem(:ticket, user_ticket, tournament.id)
      |> repo.transaction()
      |> case do
        # Погашение возвращает строку, прочитанную под блокировкой, — без
        # связанного типа билета. Номинал берётся из той, что нашёл
        # `find_for/3`: он там уже загружен, и второй запрос за ним не нужен.
        {:ok, %{ticket: redeemed}} ->
          {:ok, %{entries: [], ticket: %{redeemed | ticket: user_ticket.ticket}}}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  defp find_ticket(user_id, setting_id) do
    case Tickets.find_for(user_id, setting_id) do
      {:ok, user_ticket} -> {:ok, user_ticket}
      {:error, :not_found} -> {:error, :ticket_required}
    end
  end

  defp stake_type(:entry), do: :tournament_entry
  defp stake_type(:reentry), do: :tournament_rebuy

  # Номер входа — часть ключа и у первичной регистрации тоже. Без него
  # игрок, разрегистрировавшийся и вошедший снова, повторил бы ключ своей
  # первой оплаты, а кошелёк по правилу идемпотентности вернул бы старую
  # запись вместо нового списания — то есть пустил бы второй раз даром.
  defp reference_of(:entry, tid, uid, n), do: "tournament:#{tid}:entry:#{uid}:#{n}"
  defp reference_of(:reentry, tid, uid, n), do: "tournament:#{tid}:rebuy:#{uid}:#{n}"

  @doc """
  Как раскладывается цена входа: ставка (взнос), комиссия и голова.

  Единственное место, где деление вообще происходит. `stake` — то, что
  списывается как взнос; из него `bounty` уходит на голову игрока, а
  остаток в призовой фонд. `fee` — доход рума, ни в фонд, ни в голову.
  """
  @spec price_of(TournamentSetting.t(), :entry | :reentry) :: %{
          total: non_neg_integer(),
          stake: non_neg_integer(),
          fee: non_neg_integer(),
          bounty: non_neg_integer(),
          prize: non_neg_integer()
        }
  def price_of(%TournamentSetting{} = setting, :entry) do
    %{
      total: TournamentSetting.entry_price(setting),
      stake: setting.buy_in,
      fee: setting.entry_fee,
      bounty: setting.bounty_part,
      prize: Bounty.prize_part(setting.buy_in, setting.bounty_part)
    }
  end

  def price_of(%TournamentSetting{} = setting, :reentry) do
    split = TournamentSetting.reentry_split(setting)

    %{
      total: TournamentSetting.reentry_price(setting),
      stake: split.prize + split.bounty,
      fee: split.fee,
      bounty: split.bounty,
      prize: split.prize
    }
  end

  defp insert_entry(repo, changes, user_id, kind) do
    %{tournament: tournament, setting: setting, slot: slot, payment: payment} = changes

    attrs = %{
      tournament_id: tournament.id,
      user_id: user_id,
      entry_number: slot.entry_number,
      status: :registered,
      bounty: price_of(setting, kind).bounty,
      paid_with_ticket_id: payment.ticket && payment.ticket.id,
      # Сколько этот вход внёс в фонд. Хранится у входа, а не выводится из
      # цены шаблона: билет вносит по своему номиналу, а цена шаблона могла
      # с тех пор измениться.
      credited: credit_of(setting, kind, payment.ticket)
    }

    %Entry{}
    |> Entry.changeset(attrs)
    |> repo.insert()
    |> case do
      {:ok, entry} ->
        {:ok, entry}

      # Двойной клик: вход с этим номером уже есть. Не ошибка, а факт.
      {:error, changeset} ->
        if duplicate?(changeset), do: {:error, :already_registered}, else: {:error, changeset}
    end
  end

  defp bump_counters(repo, changes, kind) do
    %{tournament: tournament, slot: slot, entry: entry} = changes

    updates =
      [entries_count: 1, collected: entry.credited]
      |> then(&if slot.new_player?, do: Keyword.put(&1, :players_count, 1), else: &1)
      |> then(&if kind == :reentry, do: Keyword.put(&1, :reentries_count, 1), else: &1)
      |> then(&Keyword.put(&1, :bounty_pool, entry.bounty))
      |> Enum.reject(fn {_key, value} -> value == 0 end)

    {1, _returned} =
      repo.update_all(from(t in Tournament, where: t.id == ^tournament.id), inc: updates)

    {:ok, :counted}
  end

  @doc """
  Откат повторного входа: вход не сел за стол, деньги возвращаются.

  Компенсация, как и `refund_addon/2`, и по той же причине: между оплатой
  и посадкой лежит вызов к чужому процессу. Стол мог отказать — свободных
  мест не осталось, представление турнира о рассадке разошлось с самими
  комнатами. Оставленный как есть, такой вход был бы худшим из состояний:
  игрок заплатил, за столом не сидит, фишек не получил, а прежний его
  вылет так и не стал окончательным — места в турнирной таблице у него
  нет ни одного.

  `unregister/2` для этого не годится: она снимает вход по игроку и
  только до первой карты, а здесь турнир давно идёт и откатить нужно
  ровно ту запись, которую только что завели.

  Ре-энтри билетом не оплачивается (см. `register/3`), поэтому возврат
  здесь всегда денежный.
  """
  @spec refund_reentry(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | {:error, term()}
  def refund_reentry(tournament_id, entry_id) do
    Multi.new()
    |> Multi.run(:tournament, fn repo, _changes -> lock_tournament(repo, tournament_id) end)
    |> Multi.run(:setting, fn _repo, %{tournament: tournament} ->
      get_setting(tournament.tournament_setting_id)
    end)
    |> Multi.run(:entry, fn repo, _changes -> fetch_entry(entry_id, repo) end)
    |> Multi.run(:refund, fn repo, changes -> refund_entry(repo, changes) end)
    # Запись помечается возвращённой, а не удаляется: номер входа держит
    # ключ идемпотентности списания, и переиспользовать его нельзя (та же
    # причина, что в `unregister/2`).
    |> Multi.run(:release, fn repo, %{entry: entry} ->
      entry |> Entry.changeset(%{status: :refunded}) |> repo.update()
    end)
    |> Multi.run(:counters, fn repo, changes ->
      {1, _returned} =
        repo.update_all(from(t in Tournament, where: t.id == ^changes.tournament.id),
          inc: [
            entries_count: -1,
            reentries_count: -1,
            collected: -changes.entry.credited,
            bounty_pool: -changes.entry.bounty
          ]
        )

      {:ok, :updated}
    end)
    |> Multi.run(:pool, fn repo, changes -> refix_pool(repo, changes) end)
    |> Repo.transaction()
    |> case do
      {:ok, %{entry: entry, refund: written}} ->
        Enum.each(written, &Wallet.publish(entry.user_id, &1))
        announce_tournament(tournament_id)
        :ok

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc """
  Взять повторный вход из-за стола: оплата **и** посадка.

  Транспорту нужна именно эта функция, а не `reenter/2`: та берёт только
  деньги, потому что зовёт её сам турнир, у которого рассадка уже в
  руках. Позови транспорт `reenter/2` напрямую — и игрок заплатит, но
  за стол не сядет, а окно ре-энтри у турнира дотикает до вылета.
  """
  @spec take_reentry(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, atom()}
  def take_reentry(tournament_id, user_id) do
    TournamentServer.reenter(tournament_id, user_id)
  end

  @doc """
  Взять аддон: оплата **и** фишки за столом.

  По той же причине, что и `take_reentry/2`: `addon/2` только списывает,
  а фишки кладёт стол по указанию турнира. Заодно турнир и решает, можно
  ли аддон сейчас, — это знание про перерыв и уровень, а не про деньги.
  """
  @spec take_addon(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, atom()}
  def take_addon(tournament_id, user_id) do
    TournamentServer.addon(tournament_id, user_id)
  end

  # --- Разрегистрация и отмена ---------------------------------------------

  @doc """
  Разрегистрация до старта: взнос и комиссия возвращаются, билет — тоже.

  После старта выйти нельзя: место в структуре продано, и уход означал бы,
  что оставшиеся играют за приз, часть которого унесли.
  """
  @spec unregister(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | {:error, atom()}
  def unregister(tournament_id, user_id) do
    Multi.new()
    |> Multi.run(:tournament, fn repo, _changes -> lock_tournament(repo, tournament_id) end)
    |> Multi.run(:guard, fn _repo, %{tournament: tournament} ->
      if Tournament.pre_game?(tournament),
        do: {:ok, :allowed},
        else: {:error, :unregister_too_late}
    end)
    |> Multi.run(:setting, fn _repo, %{tournament: tournament} ->
      get_setting(tournament.tournament_setting_id)
    end)
    |> Multi.run(:entry, fn repo, %{tournament: tournament} ->
      case active_entry(repo, tournament.id, user_id) do
        nil -> {:error, :not_registered}
        entry -> {:ok, entry}
      end
    end)
    |> Multi.run(:refund, fn repo, changes -> refund_entry(repo, changes) end)
    # Вход по билету денег не возвращает — их и не списывали, — но билет
    # обязан вернуться той же транзакцией: иначе есть окно, в котором
    # игрок уже не в турнире и ещё без билета, а при откате он остался бы
    # без билета навсегда.
    |> Multi.run(:ticket, fn repo, %{entry: entry} -> return_ticket(repo, entry) end)
    # Запись входа **не удаляется**, а помечается возвращённой. Удаление
    # освободило бы номер входа, а из номера строится ключ идемпотентности
    # списания: следующая регистрация того же игрока выглядела бы для
    # кошелька ретраем первой, и он пустил бы её бесплатно.
    |> Multi.run(:release, fn repo, %{entry: entry} ->
      entry |> Entry.changeset(%{status: :refunded}) |> repo.update()
    end)
    |> Multi.run(:counters, fn repo, changes ->
      {1, _returned} =
        repo.update_all(from(t in Tournament, where: t.id == ^changes.tournament.id),
          inc: [
            entries_count: -1,
            players_count: -1,
            collected: -changes.entry.credited,
            bounty_pool: -changes.entry.bounty
          ]
        )

      {:ok, :updated}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{refund: refund, entry: entry, setting: setting, tournament: tournament}} ->
        Enum.each(refund, &Wallet.publish(user_id, &1))

        # Строка нулевая по деньгам, но она есть: иначе «сыграно
        # турниров» и «зарегистрировано» разойдутся необъяснимо.
        History.persist_tournament_result_async(
          result_snapshot(tournament, setting, entry, %{
            outcome: :unregistered,
            refund: refund_amount(setting, entry)
          })
        )

        drop_seat(entry)
        announce_tournament(tournament_id)
        :ok

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc """
  Отменяет турнир, не набравший минимума: возвраты всем **одной**
  транзакцией.

  Частично отменённый турнир — худшее из состояний: непонятно, кому
  доплачивать. Билеты возвращаются вместе с деньгами и по той же причине:
  иначе есть окно, где игрок не в турнире и без билета.

  **Гарантия при отмене не выплачивается.** Турнир возвращает взносы —
  и только. GTD обещает размер фонда состоявшегося турнира; несостоявшийся
  ничего не обещает. Головы возвращаются вместе со взносом: ни одна ещё
  не разыграна.
  """
  @spec cancel(Ecto.UUID.t()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def cancel(tournament_id) do
    Multi.new()
    |> Multi.run(:tournament, fn repo, _changes -> lock_tournament(repo, tournament_id) end)
    |> Multi.run(:guard, fn _repo, %{tournament: tournament} ->
      if Tournament.pre_game?(tournament),
        do: {:ok, :allowed},
        else: {:error, :tournament_started}
    end)
    |> Multi.run(:setting, fn _repo, %{tournament: tournament} ->
      get_setting(tournament.tournament_setting_id)
    end)
    |> Multi.run(:entries, fn repo, %{tournament: tournament} ->
      {:ok, repo.all(from e in Entry, where: e.tournament_id == ^tournament.id)}
    end)
    |> Multi.run(:refunds, fn repo, changes ->
      Enum.reduce_while(changes.entries, {:ok, []}, fn entry, {:ok, acc} ->
        case refund_entry(repo, Map.put(changes, :entry, entry)) do
          {:ok, written} -> {:cont, {:ok, [{entry.user_id, written} | acc]}}
          error -> {:halt, error}
        end
      end)
    end)
    |> Multi.update_all(
      :release,
      from(e in Entry, where: e.tournament_id == ^tournament_id),
      set: [status: :refunded]
    )
    |> Tickets.refund_all(:tickets, tournament_id)
    |> Multi.run(:status, fn repo, %{tournament: tournament} ->
      tournament |> Tournament.changeset(%{status: :cancelled}) |> repo.update()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{refunds: refunds, entries: entries, setting: setting, tournament: tournament}} ->
        Enum.each(refunds, fn {user_id, written} ->
          Enum.each(written, &Wallet.publish(user_id, &1))
        end)

        # Дожившие до отмены получают строку истории наравне с
        # вылетевшими. Без неё ROI врёт: взнос был, а расхода в статистике
        # нет — и период выглядит прибыльнее, чем он был.
        Enum.each(entries, fn entry ->
          History.persist_tournament_result_async(
            result_snapshot(tournament, setting, entry, %{
              outcome: :cancelled,
              refund: refund_amount(setting, entry)
            })
          )
        end)

        announce_tournament(tournament_id)
        {:ok, length(entries)}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # Билет одного входа: возврат при разрегистрации. Отмена турнира
  # возвращает билеты пачкой (`Tickets.refund_all/3`) — там участников
  # много и перебирать их по одному незачем.
  defp return_ticket(_repo, %Entry{paid_with_ticket_id: nil}), do: {:ok, :noop}

  defp return_ticket(repo, %Entry{paid_with_ticket_id: id}) do
    case repo.get(UserTicket, id) do
      nil -> {:ok, :noop}
      user_ticket -> user_ticket |> UserTicket.refund_changeset() |> repo.update()
    end
  end

  # Возврат зеркалит списание: тот же расклад на взнос и комиссию, тот же
  # ключ идемпотентности с другим префиксом. Вход по билету денег не
  # возвращает — их и не списывали.
  defp refund_entry(_repo, %{entry: %Entry{paid_with_ticket_id: id}}) when not is_nil(id) do
    {:ok, []}
  end

  defp refund_entry(repo, %{entry: entry, setting: setting, tournament: tournament}) do
    kind = if entry.entry_number == 1, do: :entry, else: :reentry
    price = price_of(setting, kind)

    if price.total == 0 do
      {:ok, []}
    else
      with {:ok, wallet} <- Wallet.get_wallet(entry.user_id, setting.currency) do
        Multi.new()
        |> Wallet.record_entry(:refund, %{
          wallet_id: wallet.id,
          amount: price.total,
          type: :tournament_refund,
          ref_id: tournament.id,
          idempotency_key: "tournament:#{tournament.id}:refund:#{entry.id}"
        })
        |> repo.transaction()
        |> case do
          {:ok, %{refund: written}} -> {:ok, [written]}
          {:error, _step, reason, _changes} -> {:error, reason}
        end
      end
    end
  end

  # --- Аддон ---------------------------------------------------------------

  @doc """
  Аддон: фишки за деньги на перерыве внутри разрешающего уровня.

  Право взять аддон проверяет процесс (уровень и перерыв — его знание),
  сюда приходит уже решённое «можно». Голову аддон **не увеличивает**:
  `addon_cost` целиком идёт в призовой фонд, потому что голова берётся
  из взноса, а аддон взносом не является.

  **Аддон один на вход, и это правило, а не настройка.** Аддон — точка
  структуры турнира: все получают одну и ту же возможность добрать один
  и тот же стек за одну и ту же цену. Второй аддон превратил бы её
  в докупку без потолка — за пять минут перерыва игрок собрал бы стек,
  не ограниченный ничем, кроме кошелька, и структура мест перестала бы
  что-либо значить. Ре-энтри лимита не наследует: новый вход — новый
  стек и новое право на аддон.
  """
  @spec addon(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, Entry.t()} | {:error, atom()}
  def addon(tournament_id, user_id) do
    Multi.new()
    |> Multi.run(:tournament, fn repo, _changes -> lock_tournament(repo, tournament_id) end)
    |> Multi.run(:setting, fn _repo, %{tournament: tournament} ->
      get_setting(tournament.tournament_setting_id)
    end)
    |> Multi.run(:live, fn _repo, %{tournament: tournament} ->
      # Доигранный или отменённый турнир денег не берёт. Право взять
      # аддон проверяет процесс, но процесс мог и не дожить: снятая
      # с него проверка оставила бы платёж, которому некуда лечь.
      if Tournament.over?(tournament), do: {:error, :addon_not_allowed}, else: {:ok, :live}
    end)
    |> Multi.run(:entry, fn repo, %{tournament: tournament} ->
      # Строка входа блокируется: `addons_count` читается и увеличивается
      # в разных шагах, и без блокировки два одновременных запроса оба
      # увидели бы ноль.
      case active_entry(repo, tournament.id, user_id, lock: true) do
        nil ->
          {:error, :not_registered}

        %Entry{addons_count: taken} when taken >= @addons_per_entry ->
          {:error, :addon_already_taken}

        entry ->
          {:ok, entry}
      end
    end)
    |> Multi.run(:charge, fn repo, changes -> charge_addon(repo, changes) end)
    |> Multi.run(:count, fn repo, changes ->
      {1, _returned} =
        repo.update_all(from(e in Entry, where: e.id == ^changes.entry.id),
          inc: [addons_count: 1]
        )

      {1, _returned} =
        repo.update_all(from(t in Tournament, where: t.id == ^changes.tournament.id),
          # Аддон идёт в фонд целиком: голову он не увеличивает, потому
          # что голова берётся из взноса, а аддон взносом не является.
          inc: [addons_count: 1, collected: changes.setting.addon_cost]
        )

      {:ok, :counted}
    end)
    |> Multi.run(:pool, fn repo, changes -> refix_pool(repo, changes) end)
    |> Repo.transaction()
    |> case do
      {:ok, %{entry: entry, charge: written}} ->
        Enum.each(written, &Wallet.publish(user_id, &1))
        announce_tournament(tournament_id)
        {:ok, entry}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc """
  Откат аддона: деньги назад, счётчики назад, фонд обратно к тому, чем был.

  Компенсация, а не «отмена по желанию»: взять её вправе только тот, кто
  аддон и провёл, — процесс турнира, у которого стол отказался принять
  фишки. Между списанием и выдачей фишек лежит вызов к чужому процессу,
  и он может не пройти: представление турнира о том, где сидит игрок,
  разошлось с самой комнатой. Оставить в этот момент как есть значило бы
  взять деньги и не дать за них ничего.

  Транзакция одна: возврат, `addons_count` у входа и у инстанса,
  `collected` и — если фонд уже зафиксирован — сам фонд с оверлеем.
  Ключ идемпотентности зеркалит ключ списания, поэтому повторный откат
  второй записи не создаёт.
  """
  @spec refund_addon(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | {:error, term()}
  def refund_addon(tournament_id, entry_id) do
    Multi.new()
    |> Multi.run(:tournament, fn repo, _changes -> lock_tournament(repo, tournament_id) end)
    |> Multi.run(:setting, fn _repo, %{tournament: tournament} ->
      get_setting(tournament.tournament_setting_id)
    end)
    |> Multi.run(:entry, fn repo, _changes -> fetch_entry(entry_id, repo) end)
    |> Multi.run(:credit, fn repo, changes -> credit_addon_refund(repo, changes) end)
    |> Multi.run(:count, fn repo, changes ->
      {1, _returned} =
        repo.update_all(from(e in Entry, where: e.id == ^changes.entry.id),
          inc: [addons_count: -1]
        )

      {1, _returned} =
        repo.update_all(from(t in Tournament, where: t.id == ^changes.tournament.id),
          inc: [addons_count: -1, collected: -changes.setting.addon_cost]
        )

      {:ok, :counted}
    end)
    |> Multi.run(:pool, fn repo, changes -> refix_pool(repo, changes) end)
    |> Repo.transaction()
    |> case do
      {:ok, %{entry: entry, credit: written}} ->
        Enum.each(written, &Wallet.publish(entry.user_id, &1))
        announce_tournament(tournament_id)
        :ok

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp credit_addon_refund(_repo, %{setting: %TournamentSetting{addon_cost: 0}}), do: {:ok, []}

  defp credit_addon_refund(repo, %{setting: setting, tournament: tournament, entry: entry}) do
    with {:ok, wallet} <- Wallet.get_wallet(entry.user_id, setting.currency) do
      Multi.new()
      |> Wallet.record_entry(:refund, %{
        wallet_id: wallet.id,
        amount: setting.addon_cost,
        type: :tournament_refund,
        ref_id: tournament.id,
        idempotency_key:
          "tournament:#{tournament.id}:addon_refund:#{entry.id}:#{entry.addons_count}"
      })
      |> repo.transaction()
      |> case do
        {:ok, %{refund: written}} -> {:ok, [written]}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  # Фонд, зафиксированный до аддона, обязан фиксацию пережить.
  #
  # `close_late_reg/1` фиксирует `prize_pool` по стенным часам, а перерыв
  # с аддоном приходит по часам уровня — те стоят на каждом перерыве и
  # отстают от стенных примерно на пять минут в час. То есть аддонный
  # перерыв наступает **после** фиксации почти всегда, а не в редком
  # случае. Пока фонд не пересчитывался, эти деньги уходили в `collected`
  # и не доставались никому: `payouts/1` считает от `prize_pool`.
  #
  # Пересчёт идёт тем же `TournamentPayout.pool/2`, что и сама фиксация, —
  # оверлей при этом честно уменьшается: рум доплачивает разницу до
  # гарантии, а не сверх собранного.
  #
  # До фиксации делать нечего: `prize_pool` там ноль, и `close_late_reg/1`
  # посчитает его от уже увеличенного `collected` сам.
  defp refix_pool(repo, %{tournament: tournament, setting: setting}) do
    case repo.get(Tournament, tournament.id) do
      %Tournament{prize_pool: pool} = fresh when pool > 0 ->
        %{prize_pool: prize_pool, overlay: overlay} =
          TournamentPayout.pool(collected(fresh), setting.guarantee)

        {1, _returned} =
          repo.update_all(from(t in Tournament, where: t.id == ^fresh.id),
            set: [prize_pool: prize_pool, overlay: overlay]
          )

        {:ok, prize_pool}

      _not_fixed ->
        {:ok, :not_fixed}
    end
  end

  defp charge_addon(_repo, %{setting: %TournamentSetting{addon_cost: 0}}),
    do: {:error, :addon_not_allowed}

  defp charge_addon(repo, %{setting: setting, tournament: tournament, entry: entry}) do
    with {:ok, wallet} <- Wallet.get_wallet(entry.user_id, setting.currency) do
      Multi.new()
      |> Wallet.record_entry(:addon, %{
        wallet_id: wallet.id,
        amount: -setting.addon_cost,
        type: :tournament_addon,
        ref_id: tournament.id,
        idempotency_key: "tournament:#{tournament.id}:addon:#{entry.id}:#{entry.addons_count + 1}"
      })
      |> repo.transaction()
      |> case do
        {:ok, %{addon: written}} -> {:ok, [written]}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  # --- Фонд ----------------------------------------------------------------

  @doc """
  Собранное в призовой фонд на текущий момент.

  Читается колонкой, а не считается по счётчикам входов. Счётчики дали бы
  верное число только там, где все входы одинаковой цены, — а вход по
  билету её ломает: билет пускает по своему `face_value`, взятому на
  момент выдачи, и если турнир с тех пор подорожал, разницу доплачивает
  рум. Считать такой вход по сегодняшней цене значило бы записать в фонд
  деньги, которых никто не вносил.

  `entry_fee` сюда не входит — это доход рума; `bounty_part` тоже — головы
  игроки платят друг другу.
  """
  @spec collected(Tournament.t()) :: non_neg_integer()
  def collected(%Tournament{collected: collected}), do: collected

  @doc """
  Призовая часть конкретного входа: сколько он вносит в фонд.

  Вход по билету зачитывается по номиналу билета, а не по цене шаблона.
  Голова и комиссия вычитаются в той же пропорции, что и у денежного
  входа: билет оплачивает **вход целиком**, включая обе эти части.
  """
  @spec credit_of(TournamentSetting.t(), :entry | :reentry, UserTicket.t() | nil) ::
          non_neg_integer()
  def credit_of(%TournamentSetting{} = setting, kind, nil), do: price_of(setting, kind).prize

  def credit_of(%TournamentSetting{} = setting, _kind, %UserTicket{ticket: ticket}) do
    # Комиссия и голова — **фиксированные суммы** шаблона, а не доли цены:
    # рум берёт свои сто единиц независимо от того, чем оплачен вход, и
    # голова стоит столько же, сколько у соседа за столом. Поэтому они
    # вычитаются из номинала как есть, а в фонд идёт остаток.
    #
    # Если турнир подорожал так, что номинала не хватает даже на них,
    # в фонд не уходит ничего: доплачивает рум, но отрицательного взноса
    # не бывает.
    max(ticket.face_value - setting.entry_fee - setting.bounty_part, 0)
  end

  @doc """
  Закрывает позднюю регистрацию и **фиксирует фонд**.

  После этого новых денег в турнире нет по построению: все ре-энтри и
  аддоны учтены до фиксации. Оверлей записывается отдельной строкой при
  выплате — рум должен видеть, сколько он доложил, а не выводить это
  разницей двух сумм.
  """
  @spec close_late_reg(Tournament.t()) :: {:ok, Tournament.t()} | {:error, term()}
  def close_late_reg(%Tournament{} = tournament) do
    with {:ok, setting} <- get_setting(tournament.tournament_setting_id) do
      %{prize_pool: pool, overlay: overlay} =
        TournamentPayout.pool(collected(tournament), setting.guarantee)

      # Статус назад не откатывается. В коротком турнире финальный стол
      # собирается раньше, чем истекает окно входа, и `:finishing` — уже
      # более поздняя стадия: перевести его в `:late_reg_closed` значило
      # бы объявить клиенту, что финалка распалась.
      status = if tournament.status == :finishing, do: :finishing, else: :late_reg_closed

      tournament
      |> Tournament.changeset(%{status: status, prize_pool: pool, overlay: overlay})
      |> Repo.update()
      |> announce()
    end
  end

  @doc """
  Выплаты турнира: список мест с суммами и билетами.

  Считается чистым ядром (`Engine.TournamentPayout`) от зафиксированного
  фонда, числа входов и числа **уникальных** участников. Последнее и есть
  усечение при ре-энтри: сетка на 60 мест при 50 живых людях неисполнима.

  Сетка — инстанса, а не шаблона (`grid_of/2`): по этой функции пишутся
  деньги, и разойтись с суммой, уже объявленной вылетевшему, ей нельзя.
  """
  @spec payouts(Tournament.t()) :: {:ok, [TournamentPayout.payout()]} | {:error, term()}
  def payouts(%Tournament{} = tournament) do
    with {:ok, setting} <- get_setting(tournament.tournament_setting_id) do
      {:ok,
       TournamentPayout.compute(
         grid_of(tournament, setting),
         tournament.entries_count,
         tournament.players_count,
         tournament.prize_pool
       )}
    end
  end

  # Сетка идущего инстанса — его собственная, из снапшота. Шаблон остаётся
  # запасным значением, и только им: инстанс без снапшота — это турнир,
  # который ещё не открывал регистрацию, и своей сетки у него пока нет.
  #
  # Одно место на обе функции намеренно. Сумма, объявленная вылетевшему
  # (`current_payouts/1`), и сумма, записанная ему в кошелёк (`settle/2`
  # через `payouts/1`), обязаны совпадать — а совпадать они могут, только
  # если читают одну сетку одним кодом. Пока `payouts/1` брала живой
  # шаблон, правка `tournament_payouts` посреди турнира разводила эти два
  # числа, и игрок получал не то, что ему объявили.
  defp grid_of(%Tournament{} = tournament, %TournamentSetting{} = setting) do
    case snapshot_payout_grid(tournament.snapshot) do
      [] -> payout_grid(setting)
      grid -> grid
    end
  end

  @doc """
  Выплаты по текущей явке и **текущему** фонду — не дожидаясь, пока
  поздняя регистрация закроется и фонд зафиксируется.

  `tournament.prize_pool` появляется только в `close_late_reg/1` — до
  этого момента это `0`, и `payouts/1` посчитал бы каждое место нулевым.
  Игроку, вылетевшему до закрытия поздней регистрации (частый случай:
  она держится час и больше), сумма нужна раньше. Фонд здесь берётся из
  `collected` — того же живого счётчика, из которого `close_late_reg/1`
  сам фонд и фиксирует, — поэтому после фиксации результат совпадает
  с `payouts/1` ровно: `collected` дальше не меняется по построению.

  Сетка берётся из **снапшота инстанса** (`snapshot_payout_grid/1`), а не
  из шаблона: турнир уже идёт, и правка `tournament_payouts` не должна
  сдвигать сумму, объявленную вылетевшему. Тем же снапшотом считается
  призовая граница на баббле (`TournamentServer`), и обе цифры обязаны
  сходиться — иначе игрок услышит одну границу на баббле и другую при
  вылете.

  Гарантия при этом читается из шаблона: от неё зависит фонд, который
  `close_late_reg/1` фиксирует **тем же** способом, и разойтись с
  итоговым `entry.prize` здесь нельзя.
  """
  @spec current_payouts(Tournament.t()) :: {:ok, [TournamentPayout.payout()]} | {:error, term()}
  def current_payouts(%Tournament{} = tournament) do
    with {:ok, setting} <- get_setting(tournament.tournament_setting_id) do
      %{prize_pool: pool} = TournamentPayout.pool(collected(tournament), setting.guarantee)

      {:ok,
       TournamentPayout.compute(
         grid_of(tournament, setting),
         tournament.entries_count,
         tournament.players_count,
         pool
       )}
    end
  end

  @doc """
  Доля игрока, чьё место слито с соседними: одновременный вылет с равным
  стеком.

  Призы связанных мест складываются и делятся поровну, остаток — первому
  по тайбрейку (`Engine.Elimination.split_prize/2`). Живёт здесь, а не
  в процессе, потому что считать деньги вне ядра нельзя, а нужен один и
  тот же расчёт в двух местах: сумма, объявленная вылетевшему сразу
  (`TournamentServer`), и сумма, записанная в кошелёк при расчёте
  (`settle/2`), обязаны совпасть.

  Место вне списка связанных или сетка без такого места дают ноль —
  «вне призовой зоны», а не ошибку.
  """
  @spec share_of_places([TournamentPayout.payout()], [pos_integer()], pos_integer()) ::
          non_neg_integer()
  def share_of_places(payouts, shared_places, place) do
    by_place = Map.new(payouts, &{&1.place, &1.amount})
    ordered = Enum.sort(shared_places)
    total = ordered |> Enum.map(&Map.get(by_place, &1, 0)) |> Enum.sum()

    case Enum.find_index(ordered, &(&1 == place)) do
      nil -> 0
      index -> total |> Elimination.split_prize(length(ordered)) |> Enum.at(index, 0)
    end
  end

  # --- Ход турнира ---------------------------------------------------------

  @doc "Помечает начало турнира и крайний срок поздней регистрации."
  @spec start(Tournament.t(), DateTime.t() | nil) :: {:ok, Tournament.t()} | {:error, term()}
  def start(%Tournament{} = tournament, late_reg_until) do
    tournament
    |> Tournament.changeset(%{
      status: :running,
      started_at: DateTime.utc_now(),
      late_reg_until: late_reg_until
    })
    |> Repo.update()
    |> announce()
  end

  @doc """
  Отмечает входы как играющие: они сели за стол и получили стек.

  Статус пишется **в момент посадки**, а не на старте турнира: между
  «турнир начался» и «этот вход занял место» помещается и поздняя
  регистрация, и ре-энтри, и отказ стола дать место. Пока вход не сидит,
  он `:registered` — и клиент по этому статусу понимает, что открывать
  ему ещё нечего.
  """
  @spec mark_playing([Ecto.UUID.t()]) :: {:ok, non_neg_integer()}
  def mark_playing([]), do: {:ok, 0}

  def mark_playing(entry_ids) do
    {count, _} =
      Entry
      |> where([e], e.id in ^entry_ids and e.status == :registered)
      |> Repo.update_all(set: [status: :playing, updated_at: DateTime.utc_now()])

    {:ok, count}
  end

  @doc "Переводит турнир в стадию финального стола."
  @spec to_final_table(Tournament.t()) :: {:ok, Tournament.t()} | {:error, term()}
  def to_final_table(%Tournament{} = tournament) do
    tournament |> Tournament.changeset(%{status: :finishing}) |> Repo.update() |> announce()
  end

  @doc """
  Записывает окончательный вылет: статус, время и **место**.

  Место присваивается только здесь: пока идёт окно ре-энтри, вылет не
  окончателен, и записывать место было бы записью несуществующего факта.

  `shared_places` — места, слитые одновременным вылетом с равным стеком.
  Пишутся вместе с местом, потому что из `place` группа не выводится,
  а дорасчёт джобой поднимает результаты из БД (`share_of_places/3`).
  """
  @spec bust(Ecto.UUID.t(), pos_integer() | nil, [pos_integer()] | nil) ::
          {:ok, Entry.t()} | {:error, term()}
  def bust(entry_id, place, shared_places \\ nil) do
    with {:ok, entry} <- fetch_entry(entry_id) do
      entry
      |> Entry.changeset(%{
        status: :busted,
        place: place,
        shared_places: shared_places,
        busted_at: busted_at(entry)
      })
      |> Repo.update()
    end
  end

  # Время вылета ставится один раз — тем моментом, когда у входа кончились
  # фишки.
  #
  # Функция зовётся дважды за один вылет: сперва из `offer_reentry/2` без
  # места (окно открыто, вылет ещё не окончателен), потом из
  # `finalize_bust/3` с местом. Второй вызов приходит по истечении окна —
  # и, перезаписывая `busted_at`, сдвигал бы время вылета на минуту-другую
  # вперёд. По нему считается `finished_at` в истории, то есть длительность
  # турнира для игрока.
  defp busted_at(%Entry{busted_at: nil}), do: DateTime.utc_now()
  defp busted_at(%Entry{busted_at: at}), do: at

  @doc """
  Сколько игрок заработал, выбивая чужие головы в этом турнире.

  Не то же самое, что `entry.bounty` (цена **его собственной** головы —
  растёт при PKO и достаётся тому, кто выбьет уже его). Отдельного
  счётчика «заработано» нет ни у входа, ни у турнира: цифра — это сумма
  записей `tournament_bounty` в кошельке игрока с меткой (`ref_id`)
  этого турнира, а платит их `credit_bounty/3` сразу после раздачи, где
  засчитан вылет жертвы.

  `0`, если у турнира нет баунти или кошелёк ещё не заведён — оба случая
  для UI неотличимы от «ничего не заработал».
  """
  @spec bounty_earned(Ecto.UUID.t(), :main | :play_money, Ecto.UUID.t()) :: non_neg_integer()
  def bounty_earned(user_id, currency, tournament_id) do
    case Wallet.get_wallet(user_id, currency) do
      {:ok, wallet} -> Wallet.sum_by_ref(wallet.id, :tournament_bounty, tournament_id)
      {:error, _reason} -> 0
    end
  end

  @doc """
  Выплата головы — **сразу после раздачи**, в которой засчитан вылет.

  Немедленная выплата и есть смысл баунти, поэтому головы выпадают из
  правила «все выплаты одной транзакцией». Риск частичности снимается
  тем, что каждая голова самодостаточна: ключ идемпотентности строится
  по входу **жертвы**, и голова конкретного входа выплачивается ровно
  один раз — это гарантирует БД, а не код.

  Прирост собственной головы убийцы в ledger не пишется: это
  обязательство турнира, а не деньги в кошельке. Деньгами он станет,
  когда убийцу выбьют или он победит.
  """
  @spec pay_bounty(Tournament.t(), Bounty.result()) :: :ok | {:error, term()}
  def pay_bounty(%Tournament{} = tournament, %{
        payouts: payouts,
        increments: increments,
        refunds: refunds
      }) do
    with {:ok, setting} <- get_setting(tournament.tournament_setting_id) do
      Multi.new()
      |> pay_bounty_cash(tournament, setting, payouts)
      |> pay_bounty_cash(tournament, setting, refunds_as_payouts(refunds))
      |> raise_bounties(increments)
      |> mark_bounty_paid(payouts)
      |> Repo.transaction()
      |> case do
        {:ok, _changes} -> :ok
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  # Возврат головы владельцу (вылет не в раздаче) — та же денежная
  # операция, что и выплата убийце, и отличается только получателем.
  defp refunds_as_payouts(refunds) do
    Enum.map(refunds, fn refund ->
      %{entry_id: refund.entry_id, victim_entry_id: refund.entry_id, amount: refund.amount}
    end)
  end

  defp pay_bounty_cash(multi, tournament, setting, payouts) do
    Enum.reduce(payouts, multi, fn payout, acc ->
      Multi.run(acc, {:bounty, payout.victim_entry_id, payout.entry_id}, fn repo, _changes ->
        credit_bounty(repo, tournament, setting, payout)
      end)
    end)
  end

  defp credit_bounty(repo, tournament, setting, payout) do
    with {:ok, entry} <- fetch_entry(payout.entry_id, repo),
         {:ok, wallet} <- Wallet.get_wallet(entry.user_id, setting.currency) do
      Multi.new()
      |> Wallet.record_entry(:bounty, %{
        wallet_id: wallet.id,
        amount: payout.amount,
        type: :tournament_bounty,
        ref_id: tournament.id,
        # Инстанса в ключе нет намеренно: `entry_id` — binary_id, уникальный
        # сам по себе, и добавлять к нему турнир значило бы не усилить
        # гарантию, а выйти за 120 символов колонки. Турнир виден
        # в `ref_id`. Убийца в ключе нужен: при сплит-поте одна голова
        # честно делится между несколькими, и каждая доля — своя запись.
        idempotency_key: "bounty:#{payout.victim_entry_id}:#{payout.entry_id}"
      })
      |> repo.transaction()
      |> case do
        {:ok, %{bounty: written}} ->
          Wallet.publish(entry.user_id, written)
          {:ok, written}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  # Приросты складываются по входу до того, как станут шагами `Multi`.
  # Двойной нокаут одной раздачей даёт **два** прироста одному убийце,
  # а имя шага в `Multi` уникально: без свёртки такая раздача роняла бы
  # процесс турнира на ровном месте.
  defp raise_bounties(multi, increments) do
    increments
    |> Enum.group_by(& &1.entry_id, & &1.amount)
    |> Enum.reduce(multi, fn {entry_id, amounts}, acc ->
      Multi.update_all(
        acc,
        {:raise, entry_id},
        from(e in Entry, where: e.id == ^entry_id),
        inc: [bounty: Enum.sum(amounts)]
      )
    end)
  end

  defp mark_bounty_paid(multi, payouts) do
    payouts
    |> Enum.group_by(& &1.victim_entry_id, & &1.amount)
    |> Enum.reduce(multi, fn {victim_entry_id, amounts}, acc ->
      total = Enum.sum(amounts)

      Multi.update_all(
        acc,
        {:paid, victim_entry_id},
        from(e in Entry, where: e.id == ^victim_entry_id),
        inc: [bounty_paid: total],
        set: [bounty: 0]
      )
    end)
  end

  @doc """
  Финальные выплаты: **одна транзакция на весь турнир**.

  Частично выплаченный турнир — худшее из состояний: непонятно,
  доплачивать или нет. Поэтому призы, оверлей, голова победителя и
  `finished_at` пишутся вместе.

  `results` — список `%{entry_id, place, shared_places}`, посчитанный
  процессом; суммы берутся из `payouts/1`, а не приходят снаружи: считать
  деньги вне ядра нельзя.

  `shared_places` — места, слитые одновременным вылетом с равным стеком:
  их призы складываются и делятся поровну (`share_of_places/3`). У
  одиночного вылета это `[place]`, и делить нечего.
  """
  @spec settle(Tournament.t(), [
          %{entry_id: term(), place: pos_integer(), shared_places: [pos_integer()]}
        ]) ::
          {:ok, [map()]} | {:error, term()}
  def settle(%Tournament{} = tournament, results) do
    with {:ok, setting} <- get_setting(tournament.tournament_setting_id),
         {:ok, payouts} <- payouts(tournament) do
      by_place = Map.new(payouts, &{&1.place, &1})
      awards = awards(results, payouts, by_place)

      Multi.new()
      |> award_prizes(tournament, setting, awards)
      |> award_winner_bounty(tournament, setting, results)
      |> record_overlay(tournament, setting)
      |> Multi.update(
        :finish,
        Tournament.changeset(tournament, %{
          status: :finished,
          finished_at: DateTime.utc_now()
        })
      )
      |> Repo.transaction()
      |> case do
        {:ok, _changes} ->
          announce_tournament(tournament.id)
          {:ok, payouts}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Кому сколько достанется — по входам, а не по местам.

  Сетка выплат (`payouts/1`) отвечает на вопрос «сколько стоит место»,
  а этот список — «сколько получит вот этот вход»: при слитых местах
  одновременного вылета это разные числа. Публична, потому что нужна
  дважды и обязана дать один ответ: по ней пишутся деньги (`settle/2`)
  и по ней же объявляется итог в канал (`TournamentServer`).
  """
  @spec award_amounts([map()], [TournamentPayout.payout()]) :: [map()]
  def award_amounts(results, payouts) do
    by_place = Map.new(payouts, &{&1.place, &1})

    results
    |> awards(payouts, by_place)
    |> Enum.map(fn {result, payout, amount} ->
      %{
        entry_id: result.entry_id,
        place: result.place,
        amount: amount,
        ticket_id: payout && payout.ticket_id
      }
    end)
  end

  # Кому сколько. Обычный случай — сумма своего места; слитые места
  # (`shared_places`) складываются и делятся поровну.
  #
  # Группа может распасться: один из связанных вошёл заново, вылета
  # у него нет, и в `results` он не попал. Делить тогда не с кем —
  # оставшийся получает своё место целиком.
  defp awards(results, payouts, by_place) do
    results
    |> Enum.group_by(&shared_places/1)
    |> Enum.flat_map(fn {places, members} ->
      if length(members) == length(places) do
        Enum.map(members, fn member ->
          {member, Map.get(by_place, member.place),
           share_of_places(payouts, places, member.place)}
        end)
      else
        Enum.map(members, fn member ->
          payout = Map.get(by_place, member.place)
          {member, payout, (payout && payout.amount) || 0}
        end)
      end
    end)
    |> Enum.reject(fn {_member, payout, amount} -> payout == nil and amount == 0 end)
  end

  defp shared_places(%{shared_places: places}) when is_list(places) and places != [], do: places
  defp shared_places(%{place: place}), do: [place]

  defp award_prizes(multi, tournament, setting, awards) do
    Enum.reduce(awards, multi, fn {result, payout, amount}, acc ->
      acc
      |> Multi.run({:prize, result.entry_id}, fn repo, _changes ->
        credit_prize(repo, tournament, setting, result, amount)
      end)
      |> Multi.update_all(
        {:mark, result.entry_id},
        from(e in Entry, where: e.id == ^result.entry_id),
        set: [status: :paid, place: result.place, prize: amount]
      )
      # Билет достаётся по **своему** месту и не делится: разрезать
      # билет пополам нечем. Слитые места, где билет есть только
      # у верхнего, отдают его тому, кто это место занял.
      |> maybe_award_ticket(tournament, result, payout)
    end)
  end

  defp credit_prize(_repo, _tournament, _setting, _result, 0), do: {:ok, :noop}

  defp credit_prize(repo, tournament, setting, result, amount) do
    with {:ok, entry} <- fetch_entry(result.entry_id, repo),
         {:ok, wallet} <- Wallet.get_wallet(entry.user_id, setting.currency) do
      Wallet.record_entry(Multi.new(), :prize, %{
        wallet_id: wallet.id,
        amount: amount,
        type: :tournament_prize,
        ref_id: tournament.id,
        idempotency_key: "tournament:#{tournament.id}:prize:#{entry.id}"
      })
      |> repo.transaction()
      |> case do
        {:ok, %{prize: written}} ->
          Wallet.publish(entry.user_id, written)
          {:ok, written}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  defp maybe_award_ticket(multi, _tournament, _result, nil), do: multi
  defp maybe_award_ticket(multi, _tournament, _result, %{ticket_id: nil}), do: multi

  defp maybe_award_ticket(multi, tournament, result, payout) do
    Multi.run(multi, {:ticket, result.entry_id}, fn repo, _changes ->
      with {:ok, entry} <- fetch_entry(result.entry_id, repo) do
        Tickets.issue(Multi.new(), :issued, %{
          ticket_id: payout.ticket_id,
          user_id: entry.user_id,
          issued_by: "tournament:#{tournament.id}"
        })
        |> repo.transaction()
        |> case do
          {:ok, %{issued: issued}} -> {:ok, issued}
          {:error, _step, reason, _changes} -> {:error, reason}
        end
      end
    end)
  end

  # Победитель забирает собственную голову деньгами — иначе `bounty_part`
  # победителя не был бы выплачен никому, и инвариант голов не сошёлся бы.
  defp award_winner_bounty(multi, tournament, setting, results) do
    case Enum.find(results, &(&1.place == 1)) do
      nil ->
        multi

      winner ->
        Multi.run(multi, :winner_bounty, fn repo, _changes ->
          with {:ok, entry} <- fetch_entry(winner.entry_id, repo) do
            case Bounty.winner_payout(entry.id, entry.bounty) do
              [] ->
                {:ok, :noop}

              [payout] ->
                credit_bounty(
                  repo,
                  tournament,
                  setting,
                  Map.put(payout, :victim_entry_id, entry.id)
                )
            end
          end
        end)
    end
  end

  # Оверлей — отдельная строка журнала, а не разница двух сумм: рум
  # должен видеть, сколько он доложил, глазами, а не выводить это.
  defp record_overlay(multi, %Tournament{overlay: 0}, _setting), do: multi

  defp record_overlay(multi, tournament, setting) do
    Multi.run(multi, :overlay, fn repo, _changes ->
      # Оверлей списывается с кассы рума — той самой, чей баланс и есть
      # накопленный результат. Она уходит в минус законно: это источник
      # денег, а не хранилище (см. миграцию `CreateHouseWallet`).
      with {:ok, wallet} <- Wallet.house_wallet(setting.currency) do
        Multi.new()
        |> Wallet.record_entry(:overlay, %{
          wallet_id: wallet.id,
          amount: -tournament.overlay,
          type: :overlay,
          ref_id: tournament.id,
          idempotency_key: "tournament:#{tournament.id}:overlay"
        })
        |> repo.transaction()
        |> case do
          {:ok, %{overlay: written}} -> {:ok, written}
          {:error, _step, reason, _changes} -> {:error, reason}
        end
      end
    end)
  end

  # --- Снапшот рассадки ----------------------------------------------------

  @doc """
  Пишет снимок рассадки и стеков. Вызывается на каждом завершении
  раздачи, асинхронно.

  Единственное, что не выводится из остальных таблиц, — и потому
  единственное, что теряется при падении процесса турнира без него.
  """
  @spec save_snapshot(Ecto.UUID.t(), map()) :: {:ok, SeatSnapshot.t()} | {:error, term()}
  def save_snapshot(tournament_id, attrs) do
    attrs = Map.put(attrs, :tournament_id, tournament_id)

    %SeatSnapshot{}
    |> SeatSnapshot.changeset(attrs)
    # `conflict_target` MySQL не принимает: `ON DUPLICATE KEY UPDATE`
    # срабатывает по уникальному индексу сам, и указывать его нечем.
    |> Repo.insert(
      on_conflict: [
        set: [level: attrs.level, hands_played: attrs[:hands_played] || 0, seats: attrs.seats]
      ]
    )
  end

  @spec get_snapshot(Ecto.UUID.t()) :: {:ok, SeatSnapshot.t()} | {:error, :not_found}
  def get_snapshot(tournament_id) do
    case Repo.get_by(SeatSnapshot, tournament_id: tournament_id) do
      nil -> {:error, :not_found}
      snapshot -> {:ok, snapshot}
    end
  end

  # --- Участники -----------------------------------------------------------

  @doc "Входы турнира — то, что показывает карточка в лобби."
  @spec list_entries(Ecto.UUID.t()) :: [Entry.t()]
  def list_entries(tournament_id) do
    Entry
    |> where([e], e.tournament_id == ^tournament_id)
    |> preload(:user)
    |> order_by([e], asc: e.entry_number, asc: e.inserted_at)
    |> Repo.all()
  end

  # Снимок входа для истории: те же поля, что пишет `TournamentServer`
  # при вылете, но по данным инстанса — здесь турнир кончился, не начавшись,
  # и процесса, который знал бы явку и число сыгранных раздач, уже нет.
  defp result_snapshot(%Tournament{} = tournament, %TournamentSetting{} = setting, entry, attrs) do
    Map.merge(
      %{
        entry_id: entry.id,
        tournament_id: tournament.id,
        user_id: entry.user_id,
        title: setting.name,
        tournament_setting_id: setting.id,
        format: :mtt,
        currency: setting.currency,
        bounty: setting.bounty_part > 0,
        entry_kind: if(entry.entry_number > 1, do: :reentry, else: :initial),
        entry_index: entry.entry_number - 1,
        buy_in: setting.buy_in,
        entry_fee: setting.entry_fee,
        addons_count: entry.addons_count,
        addons_cost: entry.addons_count * (setting.addon_cost || 0),
        bounty_final: entry.bounty,
        prize: 0,
        bounty_paid: 0,
        refund: 0,
        # Мест в неначавшемся турнире нет, и `nil` здесь означает именно
        # это, а не «место неизвестно».
        place: nil,
        entrants: tournament.entries_count,
        itm: false,
        hands_played: 0,
        started_at: entry.inserted_at,
        finished_at: DateTime.utc_now()
      },
      attrs
    )
  end

  # Вход по билету денег не возвращает — их и не списывали. Возврат
  # билета деньгами не является и в ROI не входит.
  defp refund_amount(_setting, %Entry{paid_with_ticket_id: id}) when not is_nil(id), do: 0

  defp refund_amount(setting, %Entry{entry_number: number}) do
    price_of(setting, if(number == 1, do: :entry, else: :reentry)).total
  end

  @doc "Один вход по идентификатору."
  @spec get_entry(Ecto.UUID.t()) :: {:ok, Entry.t()} | {:error, :not_found}
  def get_entry(entry_id) do
    case Repo.get(Entry, entry_id) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  @doc "Живые входы: те, что занимают место в рассадке."
  @spec list_seated(Ecto.UUID.t()) :: [Entry.t()]
  def list_seated(tournament_id) do
    Entry
    |> where([e], e.tournament_id == ^tournament_id and e.status in [:registered, :playing])
    |> Repo.all()
  end

  @doc """
  Зарегистрирован ли игрок — по нему считается фильтр «мои» в витрине.
  """
  @spec registered?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def registered?(tournament_id, user_id) do
    Entry
    |> where([e], e.tournament_id == ^tournament_id and e.user_id == ^user_id)
    |> where([e], e.status in [:registered, :playing])
    |> Repo.exists?()
  end

  @spec fetch_entry(Ecto.UUID.t(), module()) :: {:ok, Entry.t()} | {:error, :not_found}
  def fetch_entry(entry_id, repo \\ Repo) do
    case repo.get(Entry, entry_id) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  defp active_entry(repo, tournament_id, user_id, opts \\ []) do
    Entry
    |> where([e], e.tournament_id == ^tournament_id and e.user_id == ^user_id)
    |> where([e], e.status in [:registered, :playing])
    |> then(&if Keyword.get(opts, :lock, false), do: lock(&1, "FOR UPDATE"), else: &1)
    |> repo.one()
  end

  # --- Служебное -----------------------------------------------------------

  defp insert_children(repo, setting, rows, schema) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      struct(schema)
      |> schema.changeset(Map.put(row, :tournament_setting_id, setting.id))
      |> Ecto.Changeset.put_change(:tournament_setting_id, setting.id)
      |> repo.insert()
      |> case do
        {:ok, record} -> {:cont, {:ok, [record | acc]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp announce({:ok, %Tournament{} = tournament}) do
    announce_tournament(tournament.id)
    {:ok, tournament}
  end

  defp announce(other), do: other

  # Наружу ядро говорит фактом, а кто на него подписан — его не касается
  # (§3 CLAUDE.md). Событие несёт только идентификатор: подписчик читает
  # состояние сам и не зависит от того, что мы решили в него положить.
  # Процесс инстанса поднимается **первой регистрацией**, а не открытием
  # регистрации по расписанию.
  #
  # Причина арифметическая: рум запускает турниры каждые полчаса, и
  # инстансов в сутки выходит под тысячу. Держать под каждый из них
  # процесс с открытия регистрации значило бы держать сотни процессов,
  # подавляющее большинство которых не увидит ни одного игрока и
  # отменится по недобору. Пустому турниру процесс не нужен: витрине
  # хватает строки в БД, а старту — планировщика, который поднимет
  # процесс сам.
  #
  # Повторный вызов безвреден, а неудача не отменяет регистрацию: деньги
  # уже в ledger, и процесс всё равно поднимет планировщик на старте.
  defp ensure_server(tournament_id) do
    if autostart?() and TournamentServer.whereis(tournament_id) == nil do
      case TournamentSupervisor.start_tournament(tournament_id: tournament_id) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> Logger.error("не поднялся турнир: #{inspect(reason)}")
      end
    end

    :ok
  end

  # Поздняя регистрация обязана сесть за стол сама: столы уже подняты, и
  # стартовая рассадка, которая читает входы из БД, давно прошла. Турнир
  # сам решает, есть ли куда сажать — до старта столов нет, и вход
  # подберёт стартовая рассадка.
  defp seat_if_running(%Entry{} = entry) do
    if TournamentServer.whereis(entry.tournament_id) do
      case TournamentServer.seat_entry(entry.tournament_id, entry) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error("вход #{entry.id} не сел за стол: #{inspect(reason)}")
      end
    end

    :ok
  end

  # Отписавшегося убираем со стола: рассадка могла случиться за минуту до
  # старта, и место обязано освободиться вместе с возвратом взноса.
  defp drop_seat(%Entry{} = entry) do
    if TournamentServer.whereis(entry.tournament_id) do
      TournamentServer.drop_entry(entry.tournament_id, entry.id)
    end

    :ok
  end

  # В тестах процессы поднимает сам тест: `start_supervised!` даёт ему
  # и контроль над часами, и доступ к песочнице БД.
  defp autostart?, do: Application.get_env(:block_poker, :tournament_autostart, true)

  defp announce_tournament(tournament_id) do
    PubSub.broadcast(@pubsub, lobby_topic(), {:tournament_updated, tournament_id})
    PubSub.broadcast(@pubsub, topic(tournament_id), {:tournament_updated, tournament_id})
  end

  defp duplicate?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
      opts[:constraint] == :unique
    end)
  end

  defp stringify(map) do
    Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp filter_enabled(query, nil), do: query
  defp filter_enabled(query, enabled), do: where(query, [s], s.enabled == ^enabled)

  defp filter_game_types(query, []), do: query
  defp filter_game_types(query, nil), do: query
  defp filter_game_types(query, types), do: where(query, [s], s.game_type in ^types)

  defp filter_currency(query, nil), do: query
  defp filter_currency(query, currency), do: where(query, [s], s.currency == ^currency)
end
