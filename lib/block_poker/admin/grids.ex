defmodule BlockPoker.Admin.Grids do
  @moduledoc """
  Сетки всех четырёх режимов: то, из чего рум состоит, а не то, что в нём
  сейчас происходит.

  Пара к `Admin.Games` и её противоположность по источнику: `Games` читает
  живые процессы, `Grids` — строки в БД, из которых эти процессы потом
  разворачиваются. Смешивать их нельзя: правка шаблона не трогает идущую
  раздачу, а закрытие стола не меняет шаблон.

  ## Один модуль на четыре режима

  Режимы различаются набором полей, но не набором действий: завести,
  поправить, снять с сетки, вернуть. Ветвление по `kind` здесь есть и
  живёт **только** здесь — в транспорте его нет вовсе, а контексты
  режимов о панели не знают.

  ## Удаления нет

  Снятый шаблон получает `archived_at`: на строку ссылаются сыгранные
  раздачи и итоги турниров, и реплей читает из неё имя и лимиты стола.
  Удалить её значило бы сделать вчерашний разбор жалобы невозможным ради
  сегодняшней чистоты списка.

  ## Когда правка доезжает до игроков

  Не мгновенно, и это решение. Идущие комнаты доигрывают на тех условиях,
  на которых люди за них садились; новые поднимаются уже по новой строке.
  Витрины перечитывают шаблоны по таймеру, а `apply/1` просто просит их не
  ждать — своей логики у этой функции нет.
  """

  import Ecto.Query

  alias BlockPoker.Admin.{Audit, Context}
  alias BlockPoker.CashGames
  alias BlockPoker.CashGames.CashGameSetting
  alias BlockPoker.Engine.Variant.Registry, as: VariantRegistry
  alias BlockPoker.OfcGames
  alias BlockPoker.OfcGames.OfcSetting
  alias BlockPoker.Repo
  alias BlockPoker.SitAndGo
  alias BlockPoker.SitAndGo.SitAndGoSetting
  alias BlockPoker.Tables.{Lobby, SitAndGoLobby}
  alias BlockPoker.Tournaments
  alias BlockPoker.Tournaments.{TournamentScheduler, TournamentSetting}

  @kinds [:cash, :sit_and_go, :mtt, :ofc_cash]

  @level_keys [
    :level,
    :small_blind,
    :big_blind,
    :ante,
    :duration_seconds,
    :rebuy_allowed,
    :addon_allowed
  ]
  @payout_keys [:entries_from, :entries_to, :place_from, :place_to, :share_ppm, :ticket_id]
  @schedule_keys [:start_time, :weekday, :repeat, :run_on, :enabled]
  @tier_keys [:multiplier, :chance_ppm, :payouts]

  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc """
  Вид сетки из строки с провода. В отличие от фильтра живых игр разбор
  строгий: `kind` — адрес таблицы, и «непонятно что» обязано быть ошибкой,
  а не молчаливым умолчанием.
  """
  @spec kind(term()) :: {:ok, atom()} | {:error, :validation_failed}
  def kind(value) when value in @kinds, do: {:ok, value}

  def kind(value) when is_binary(value) do
    case Enum.find(@kinds, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :validation_failed}
      kind -> {:ok, kind}
    end
  end

  def kind(_value), do: {:error, :validation_failed}

  @doc """
  Справочник для форм панели: какие бывают виды покера, валюты, размеры
  стола и с чем заводится новый шаблон каждого режима.

  Живёт в ядре по той же причине, по какой здесь живёт список режимов:
  копия этих списков в панели разошлась бы с оригиналом на первом же новом
  виде покера, и оператор завёл бы стол, которого не существует.
  """
  @spec meta() :: map()
  def meta do
    %{
      kinds: @kinds,
      currencies: CashGameSetting.currencies(),
      game_types: VariantRegistry.ids(),
      ofc_game_types: OfcSetting.game_types(),
      ante_types: CashGameSetting.ante_types(),
      visibilities: CashGameSetting.visibilities(),
      table_sizes: TournamentSetting.table_sizes(),
      code_length: CashGameSetting.code_length(),
      defaults: Map.new(@kinds, &{&1, card(blank(&1))})
    }
  end

  @doc "Сетка режима. `archived: true` — только снятые, `nil` — всё вместе."
  @spec list(atom(), keyword()) :: [map()]
  def list(kind, opts \\ []) do
    kind
    |> settings(Keyword.get(opts, :archived, false))
    |> Enum.map(&card/1)
  end

  @spec get(atom(), Ecto.UUID.t()) :: {:ok, map()} | {:error, :admin_setting_not_found}
  def get(kind, id) do
    case fetch(kind, id) do
      {:ok, setting} -> {:ok, card(setting)}
      {:error, _reason} -> {:error, :admin_setting_not_found}
    end
  end

  @doc """
  Новый шаблон. У кэша и китайского покера приватная комната заводится не
  так, как публичная: код входа выдаёт сервер, а не оператор, — и решает
  это ядро, а не форма (§9 CLAUDE.md).
  """
  @spec create(Context.t(), atom(), map()) :: {:ok, map()} | {:error, atom() | Ecto.Changeset.t()}
  def create(%Context{} = ctx, kind, attrs) do
    written(ctx, kind, :grid_create, nil, fn -> do_create(kind, attrs) end)
  end

  @doc """
  Правка. Вложенные части (уровни, выплаты, расписание, таблица призов)
  заменяются целиком и только если переданы: отсутствие ключа значит «не
  трогаем», пустой список — «стереть», и второе не переживёт проверку
  шаблона.
  """
  @spec update(Context.t(), atom(), Ecto.UUID.t(), map()) ::
          {:ok, map()} | {:error, atom() | Ecto.Changeset.t()}
  def update(%Context{} = ctx, kind, id, attrs) do
    with {:ok, setting} <- fetch_for_admin(kind, id) do
      written(ctx, kind, :grid_update, nil, fn -> do_update(kind, setting, attrs) end)
    end
  end

  @doc "Снятие с сетки. Причина обязательна: список рума — не черновик."
  @spec archive(Context.t(), atom(), Ecto.UUID.t(), String.t() | nil) ::
          {:ok, map()} | {:error, atom() | Ecto.Changeset.t()}
  def archive(%Context{} = ctx, kind, id, reason) do
    with {:ok, setting} <- fetch_for_admin(kind, id) do
      written(ctx, kind, :grid_archive, reason, fn -> do_archive(kind, setting) end)
    end
  end

  @doc "Возврат из архива — выключенным, чтобы оператор сперва прочитал условия."
  @spec restore(Context.t(), atom(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, atom() | Ecto.Changeset.t()}
  def restore(%Context{} = ctx, kind, id) do
    with {:ok, setting} <- fetch_for_admin(kind, id) do
      written(ctx, kind, :grid_restore, nil, fn -> do_restore(kind, setting) end)
    end
  end

  @doc """
  Просьба перечитать сетку немедленно.

  Обе витрины и планировщик турниров перечитывают её и так, по таймеру, —
  здесь только «не жди минуту». Своей логики у функции нет и быть не
  должно: что делать с новым шаблоном, знает лобби, а не панель.
  """
  @spec apply(Context.t()) :: {:ok, map()}
  def apply(%Context{} = ctx) do
    Audit.write(ctx, %{action: :grid_reload, subject_type: :game_setting, subject_id: "all"})

    {:ok,
     %{
       cash: nudge(&Lobby.reload/0),
       sit_and_go: nudge(&SitAndGoLobby.reload/0),
       mtt: nudge(&TournamentScheduler.tick/0)
     }}
  end

  # Витрина могла не подняться (тесты, урезанное дерево процессов) — это не
  # повод ронять запрос: перечитает по таймеру.
  defp nudge(fun) do
    fun.()
    :ok
  catch
    :exit, _reason -> :unavailable
  end

  # --- запись ---------------------------------------------------------------

  # Операция и запись журнала идут одной транзакцией: контексты режимов
  # открывают свою, вложенная к ней присоединяется, и коммит у них общий
  # (§8 задачи 8). Не записалось — не произошло.
  defp written(ctx, kind, action, reason, fun) do
    Repo.transaction(fn ->
      with {:ok, setting} <- fun.(),
           {:ok, _entry} <- log(ctx, kind, action, reason, setting) do
        card(setting)
      else
        {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(failure(changeset))
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp log(ctx, kind, action, reason, setting) do
    Audit.write(ctx, %{
      action: action,
      subject_type: :game_setting,
      subject_id: setting.id,
      reason: reason,
      meta: %{kind: to_string(kind), name: setting.name}
    })
  end

  # Причина обязательна ровно там, где её требует схема журнала: второй
  # копии этого правила здесь нет.
  defp failure(%Ecto.Changeset{data: %BlockPoker.Admin.AdminAudit{}} = changeset) do
    if Keyword.has_key?(changeset.errors, :reason),
      do: :admin_reason_required,
      else: changeset
  end

  defp failure(%Ecto.Changeset{} = changeset), do: changeset

  defp do_create(:cash, attrs) do
    if private?(attrs),
      do: CashGames.create_private_setting(attrs),
      else: CashGames.create_setting(attrs)
  end

  defp do_create(:ofc_cash, attrs) do
    if private?(attrs),
      do: OfcGames.create_private_setting(attrs),
      else: OfcGames.create_setting(attrs)
  end

  defp do_create(:sit_and_go, attrs) do
    SitAndGo.create_setting(
      attrs,
      rows(attrs, "blind_levels", @level_keys),
      rows(attrs, "prize_tiers", @tier_keys)
    )
  end

  defp do_create(:mtt, attrs) do
    Tournaments.create_setting(
      attrs,
      rows(attrs, "blind_levels", @level_keys),
      rows(attrs, "payout_rows", @payout_keys),
      rows(attrs, "schedules", @schedule_keys)
    )
  end

  defp do_update(:cash, setting, attrs), do: CashGames.update_setting(setting, attrs)
  defp do_update(:ofc_cash, setting, attrs), do: OfcGames.update_setting(setting, attrs)

  defp do_update(:sit_and_go, setting, attrs) do
    SitAndGo.update_setting(
      setting,
      attrs,
      maybe_rows(attrs, "blind_levels", @level_keys),
      maybe_rows(attrs, "prize_tiers", @tier_keys)
    )
  end

  defp do_update(:mtt, setting, attrs) do
    Tournaments.update_setting(
      setting,
      attrs,
      maybe_rows(attrs, "blind_levels", @level_keys),
      maybe_rows(attrs, "payout_rows", @payout_keys),
      maybe_rows(attrs, "schedules", @schedule_keys)
    )
  end

  defp do_archive(:cash, setting), do: CashGames.archive_setting(setting)
  defp do_archive(:ofc_cash, setting), do: OfcGames.archive_setting(setting)
  defp do_archive(:sit_and_go, setting), do: SitAndGo.archive_setting(setting)
  defp do_archive(:mtt, setting), do: Tournaments.archive_setting(setting)

  defp do_restore(:cash, setting), do: CashGames.restore_setting(setting)
  defp do_restore(:ofc_cash, setting), do: OfcGames.restore_setting(setting)
  defp do_restore(:sit_and_go, setting), do: SitAndGo.restore_setting(setting)
  defp do_restore(:mtt, setting), do: Tournaments.restore_setting(setting)

  defp private?(attrs) do
    to_string(attrs["visibility"] || attrs[:visibility]) == "private"
  end

  # Вложенные строки приходят с провода с ключами-строками, а changeset
  # схемы дописывает в них ключ-атом внешнего ключа. Смешанные ключи Ecto
  # не принимает, поэтому строки приводятся к атомам здесь — и только по
  # белому списку полей, а не `String.to_atom/1` над чужим вводом.
  defp rows(attrs, key, allowed), do: maybe_rows(attrs, key, allowed) || []

  defp maybe_rows(attrs, key, allowed) do
    case attrs[key] || attrs[String.to_existing_atom(key)] do
      list when is_list(list) -> Enum.map(list, &row(&1, allowed))
      _absent -> nil
    end
  end

  defp row(row, allowed) when is_map(row) do
    # `||` здесь не годится: `false` — законное значение поля, а не
    # «ключа нет», и подмена его дефолтом схемы молча превращает разовое
    # расписание в повторяющееся.
    Map.new(allowed, fn key -> {key, field(row, key)} end)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp field(row, key) do
    case Map.fetch(row, Atom.to_string(key)) do
      {:ok, value} -> value
      :error -> Map.get(row, key)
    end
  end

  # --- чтение ---------------------------------------------------------------

  defp settings(:cash, archived) do
    CashGameSetting
    |> CashGames.filter_archived(archived)
    |> order_by(asc: :sort_order, asc: :small_blind, asc: :max_players)
    |> Repo.all()
  end

  defp settings(:ofc_cash, archived) do
    OfcSetting
    |> CashGames.filter_archived(archived)
    |> order_by(asc: :sort_order, asc: :point_value, asc: :max_players)
    |> Repo.all()
  end

  defp settings(:sit_and_go, archived) do
    SitAndGo.list_settings(enabled: nil, archived: archived)
  end

  defp settings(:mtt, archived) do
    Tournaments.list_settings(enabled: nil, archived: archived)
  end

  defp fetch(:cash, id), do: CashGames.get_setting(id)
  defp fetch(:ofc_cash, id), do: OfcGames.get_setting(id)
  defp fetch(:sit_and_go, id), do: SitAndGo.get_setting(id)
  defp fetch(:mtt, id), do: Tournaments.get_setting(id)

  # Панели «не найдено» отвечает одним кодом независимо от режима: чем
  # именно не нашлась строка — её не касается.
  defp fetch_for_admin(kind, id) do
    case fetch(kind, id) do
      {:ok, setting} -> {:ok, setting}
      {:error, _reason} -> {:error, :admin_setting_not_found}
    end
  end

  defp blank(:cash), do: %CashGameSetting{}
  defp blank(:ofc_cash), do: %OfcSetting{}
  defp blank(:sit_and_go), do: %SitAndGoSetting{blind_levels: [], prize_tiers: []}

  defp blank(:mtt), do: %TournamentSetting{blind_levels: [], payout_rows: [], schedules: []}

  # --- карточки -------------------------------------------------------------

  @doc "Карточка шаблона: ровно те поля, которые панель показывает и правит."
  @spec card(struct()) :: map()
  def card(%CashGameSetting{} = s) do
    s
    |> common(:cash)
    |> Map.merge(%{
      small_blind: s.small_blind,
      big_blind: s.big_blind,
      ante: s.ante,
      ante_type: s.ante_type,
      max_players: s.max_players,
      min_buy_in: s.min_buy_in,
      max_buy_in: s.max_buy_in,
      rake_percent: s.rake_percent,
      rake_cap_by_players: s.rake_cap_by_players,
      no_flop_no_drop: s.no_flop_no_drop,
      allow_post_blind: s.allow_post_blind,
      allowed_run_it_twice: s.allowed_run_it_twice,
      bomb_pot_chance: s.bomb_pot_chance,
      bomb_pot_ante: s.bomb_pot_ante,
      blind_dodge_window_hands: s.blind_dodge_window_hands,
      auto_start: s.auto_start,
      visibility: s.visibility,
      code: s.code,
      max_rooms: s.max_rooms,
      sit_out_timeout_ms: s.sit_out_timeout_ms,
      rebuy_prompt_ms: s.rebuy_prompt_ms,
      # Границы бай-ина в фишках считает ядро: перевод номиналов в фишки —
      # арифметика над деньгами, и во view ей не место (§3 CLAUDE.md).
      bet_unit: bet_unit(s),
      min_buy_in_chips: s.game_type && CashGameSetting.min_buy_in_chips(s),
      max_buy_in_chips: s.game_type && CashGameSetting.max_buy_in_chips(s)
    })
  end

  def card(%OfcSetting{} = s) do
    s
    |> common(:ofc_cash)
    |> Map.merge(%{
      point_value: s.point_value,
      max_players: s.max_players,
      min_buy_in: s.min_buy_in,
      max_buy_in: s.max_buy_in,
      auto_start: s.auto_start,
      visibility: s.visibility,
      code: s.code,
      max_rooms: s.max_rooms,
      sit_out_timeout_ms: s.sit_out_timeout_ms,
      rebuy_prompt_ms: s.rebuy_prompt_ms
    })
  end

  def card(%SitAndGoSetting{} = s) do
    s
    |> common(:sit_and_go)
    |> Map.merge(%{
      max_players: s.max_players,
      buy_in: s.buy_in,
      starting_stack: s.starting_stack,
      prize_reveal_ms: s.prize_reveal_ms,
      max_rooms: s.max_rooms,
      blind_levels: children(s.blind_levels, &level/1),
      prize_tiers: children(s.prize_tiers, &tier/1)
    })
  end

  def card(%TournamentSetting{} = s) do
    s
    |> common(:mtt)
    |> Map.merge(%{
      description: s.description,
      buy_in: s.buy_in,
      entry_fee: s.entry_fee,
      starting_stack: s.starting_stack,
      table_size: s.table_size,
      min_players: s.min_players,
      max_players: s.max_players,
      max_entries: s.max_entries,
      rebuy_allowed: s.rebuy_allowed,
      rebuy_cost: s.rebuy_cost,
      rebuy_stack: s.rebuy_stack,
      max_rebuys: s.max_rebuys,
      addon_cost: s.addon_cost,
      addon_stack: s.addon_stack,
      guarantee: s.guarantee,
      bounty_part: s.bounty_part,
      bounty_progressive: s.bounty_progressive,
      bounty_split_ppm: s.bounty_split_ppm,
      registration_opens_before: s.registration_opens_before,
      cancel_refund_grace_seconds: s.cancel_refund_grace_seconds,
      rebuy_prompt_ms: s.rebuy_prompt_ms,
      final_felt_color: s.final_felt_color,
      final_background_color: s.final_background_color,
      blind_levels: children(s.blind_levels, &level/1),
      payout_rows: children(s.payout_rows, &payout/1),
      schedules: children(s.schedules, &schedule/1)
    })
  end

  # Базовая единица считается только у заполненного шаблона: у пустой
  # заготовки вида покера ещё нет, а без него нет и структуры ставок.
  defp bet_unit(%CashGameSetting{game_type: nil}), do: nil
  defp bet_unit(%CashGameSetting{} = s), do: CashGameSetting.bet_unit(s)

  # Общая часть карточки: то, что есть у всех четырёх режимов.
  defp common(s, kind) do
    %{
      kind: kind,
      id: s.id,
      name: s.name,
      game_type: s.game_type,
      currency: s.currency,
      enabled: s.enabled,
      archived: not is_nil(s.archived_at),
      archived_at: s.archived_at,
      sort_order: s.sort_order,
      felt_color: s.felt_color,
      background_color: s.background_color,
      action_timeout_ms: s.action_timeout_ms,
      time_bank_ms: s.time_bank_ms,
      time_bank_refill: s.time_bank_refill,
      disconnect_grace_ms: s.disconnect_grace_ms,
      button_draw_animation_ms: s.button_draw_animation_ms,
      updated_at: s.updated_at
    }
  end

  defp children(list, fun) when is_list(list), do: Enum.map(list, fun)
  defp children(_not_loaded, _fun), do: []

  defp level(level) do
    %{
      level: level.level,
      small_blind: level.small_blind,
      big_blind: level.big_blind,
      ante: level.ante,
      duration_seconds: level.duration_seconds,
      rebuy_allowed: Map.get(level, :rebuy_allowed),
      addon_allowed: Map.get(level, :addon_allowed)
    }
  end

  defp payout(row) do
    %{
      entries_from: row.entries_from,
      entries_to: row.entries_to,
      place_from: row.place_from,
      place_to: row.place_to,
      share_ppm: row.share_ppm,
      ticket_id: row.ticket_id
    }
  end

  defp schedule(schedule) do
    %{
      start_time: schedule.start_time,
      weekday: schedule.weekday,
      repeat: schedule.repeat,
      run_on: schedule.run_on,
      enabled: schedule.enabled
    }
  end

  defp tier(tier) do
    %{multiplier: tier.multiplier, chance_ppm: tier.chance_ppm, payouts: tier.payouts}
  end
end
