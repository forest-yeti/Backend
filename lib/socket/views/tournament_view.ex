defmodule Socket.Views.TournamentView do
  @moduledoc """
  Турниры на пути в сокет.

  Транспорт, а не логика: решает, *какие* поля показать, но не вычисляет
  доменных значений. Статус витрины, признаки турнира, цена входа и число
  призовых мест приходят из ядра уже посчитанными (§3 CLAUDE.md) — здесь
  их только раскладывают по ключам.

  Два правила, которые видны в форме payload:

    * **`starts_at` всегда UTC.** Пояс рума живёт на сервере, местное
      время игрока рисует Electron. Отдавать «21:30» строкой значило бы
      заставить клиента угадывать, чьё это время;
    * **взнос и стек — разные шкалы.** Первое деньги, второе фишки, и
      складывать их нельзя.
  """

  alias BlockPoker.Engine.BlindSchedule
  alias BlockPoker.Tournaments.{LobbyEntry, TournamentSetting}

  @doc "Полная витрина: строки и словарь доступных фильтров."
  @spec render([LobbyEntry.t()]) :: map()
  def render(entries) do
    %{tournaments: Enum.map(entries, &entry/1), filters: filters()}
  end

  @doc "Одна строка витрины."
  @spec entry(LobbyEntry.t()) :: map()
  def entry(%{setting: setting, tournament: tournament} = entry) do
    %{
      # Регистрируются в **инстанс**: «Вечерний фрибай» сегодня и завтра —
      # разные турниры с одним шаблоном.
      tournament_id: entry.tournament_id,
      setting_id: entry.setting_id,
      name: setting.name,
      description: setting.description,
      game_type: setting.game_type,
      currency: setting.currency,
      status: entry.status,
      starts_at: tournament.starts_at,
      buy_in: setting.buy_in,
      entry_fee: setting.entry_fee,
      # То, что спишется с кошелька: клиенту эту сумму и показывать.
      entry_price: entry.entry_price,
      starting_stack: setting.starting_stack,
      table_size: setting.table_size,
      min_players: setting.min_players,
      guarantee: setting.guarantee,
      bounty_part: setting.bounty_part,
      # Входы и люди — разные числа, и путать их нельзя: по входам
      # считается фонд, по людям — сколько человек играет.
      entries_count: tournament.entries_count,
      players_count: tournament.players_count,
      prize_pool: max(tournament.prize_pool, tournament.collected),
      kinds: entry.kinds,
      registered: entry.registered,
      has_ticket: entry.has_ticket,
      visuals: %{
        felt_color: setting.felt_color,
        background_color: setting.background_color
      }
    }
  end

  @doc """
  Карточка турнира: структура, сетка выплат при текущей явке и чипсчёт
  с пагинацией.
  """
  @spec card(map()) :: map()
  def card(%{entry: entry, levels: levels, level_flags: flags} = card) do
    %{
      tournament: entry(entry),
      blind_levels: Enum.map(levels, &level(&1, flags)),
      payouts: Enum.map(card.payouts, &payout/1),
      chip_counts: chip_counts(card.chip_counts)
    }
  end

  @doc """
  Уровень структуры. Подпись приходит готовой: выбирать между «50/100»
  и «анте 100» — это знание о том, какая структура ставок у какой
  дисциплины, и клиенту его иметь незачем.
  """
  @spec level(BlindSchedule.level(), map()) :: map()
  def level(level, flags) do
    flag = Map.get(flags, level.level, %{rebuy_allowed: false, addon_allowed: false})

    %{
      level: level.level,
      small_blind: level.small_blind,
      big_blind: level.big_blind,
      ante: level.ante,
      duration_seconds: level.duration_seconds,
      label: BlindSchedule.label(level),
      rebuy_allowed: flag.rebuy_allowed,
      addon_allowed: flag.addon_allowed
    }
  end

  @doc "Одно призовое место: деньги, билет или и то и другое."
  @spec payout(map()) :: map()
  def payout(payout) do
    %{
      place: payout.place,
      amount: payout.amount,
      ticket: payout.ticket_id && %{ticket_id: payout.ticket_id, face_value: payout.ticket_value}
    }
  end

  @doc """
  Снимок турнира для игрока за столом: четыре счётчика и своё место.

  **Списка участников здесь нет и не будет.** При трёхстах участниках
  каждый вылет рассылал бы триста строк каждому из трёхсот подключённых,
  и трафик рос бы квадратом от размера турнира. Полный чипсчёт живёт
  в карточке лобби и запрашивается по требованию.
  """
  @spec state(map()) :: map()
  def state(state) do
    %{
      tournament_id: state.tournament_id,
      status: state.status,
      level: state.level,
      small_blind: state.limits.small_blind,
      big_blind: state.limits.big_blind,
      ante: state.limits.ante,
      players_left: state.players_left,
      entries: state.entries,
      tables: state.tables,
      on_break: state.on_break,
      # Игра «рука в руку» на пузыре: пока флаг поднят, столы ждут друг
      # друга, и пауза между раздачами — это не подвисший стол.
      hand_for_hand: state.hand_for_hand,
      next_payout_place: state.next_payout_place,
      final_table: state.final_table
    }
  end

  @doc "Событие турнира: имя и уже готовый payload от ядра."
  @spec event(String.t(), map()) :: map()
  def event(_name, payload), do: payload

  defp chip_counts(%{entries: entries} = counts) do
    %{
      entries:
        entries
        |> Enum.with_index(counts.offset + 1)
        |> Enum.map(fn {entry, rank} -> chip_row(entry, rank) end),
      total: counts.total,
      limit: counts.limit,
      offset: counts.offset
    }
  end

  defp chip_row(entry, rank) do
    %{
      rank: rank,
      entry_id: entry.entry_id,
      # Кто это: клиент отличает по нему себя в чипсчёте, а по столу
      # открывает окно с этим игроком.
      user_id: entry.user_id,
      name: entry.name,
      entry_number: entry.entry_number,
      status: entry.status,
      # Фишки, а не деньги: складывать со взносом нельзя.
      stack: entry.stack,
      # Стол этого входа. `nil` — турнир не начался или вход вылетел.
      table_id: entry.table_id,
      seat: entry.seat,
      # Цена головы публична: без неё PKO не играется — решение о колле
      # зависит от того, сколько стоит соперник.
      bounty: entry.bounty,
      place: entry.place,
      prize: entry.prize
    }
  end

  defp filters do
    %{
      game_types: BlockPoker.Engine.Variant.Registry.ids(),
      currencies: TournamentSetting.currencies(),
      table_sizes: BlockPoker.Tables.LobbyQuery.table_sizes(),
      limit_tiers: BlockPoker.Tables.LobbyQuery.limit_tiers(),
      statuses: BlockPoker.Tables.LobbyQuery.statuses(),
      kinds: BlockPoker.Tables.LobbyQuery.kinds(),
      # Чем можно сортировать. Список отдаёт сервер по той же причине,
      # что и фильтры: новая сортировка не должна требовать релиза
      # клиента.
      sort_fields: BlockPoker.Tables.LobbyQuery.tournament_sort_fields()
    }
  end
end
