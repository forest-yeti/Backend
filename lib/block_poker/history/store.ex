defmodule BlockPoker.History.Store do
  @moduledoc """
  Запись истории в MySQL: единственное место контекста, которое ходит в
  `Repo` на запись.

  Три требования, каждое со своей причиной.

  **Одна транзакция на раздачу.** Частично записанная раздача хуже
  незаписанной: она даёт неверную статистику и сломанный реплей.

  **Идемпотентность по `hands.id`.** Идентификатор раздачи заведён в
  момент её старта, а не записи, поэтому повтор задачи (ретрай, рестарт
  Writer, перезапуск ноды) находит раздачу уже записанной и не делает
  ничего. То же по `tournament_results.entry_id`, только там гарантию
  даёт unique-индекс БД, а не проверка в коде.

  **Агрегат инкрементируется, а не переписывается.** `ON DUPLICATE KEY
  UPDATE col = col + new.col` — сложение, потому что строка дня общая для
  всех раздач этого дня.
  """

  import Ecto.Query

  alias BlockPoker.History.{
    HandAction,
    HandPlayer,
    HandRecord,
    OfcHand,
    OfcHandPlayer,
    PlayerStatsDaily,
    TournamentResult
  }

  alias BlockPoker.Repo
  alias Ecto.Multi

  @stat_keys [:user_id, :day, :game_mode, :setting_id, :currency]

  @doc """
  Записать собранную раздачу. Повтор той же раздачи — no-op, а не вторая
  копия.
  """
  @spec write(map()) :: {:ok, :written | :already} | {:error, term()}
  def write(%{kind: kind} = rows) do
    {schema, player_schema} = tables(kind)
    now = DateTime.utc_now()

    Multi.new()
    |> Multi.run(:existing, fn repo, _changes ->
      {:ok, repo.get(schema, rows.hand.id)}
    end)
    |> Multi.run(:hand, fn
      _repo, %{existing: nil} ->
        schema
        |> struct()
        |> schema.changeset(rows.hand)
        |> Repo.insert()

      _repo, %{existing: existing} ->
        {:ok, existing}
    end)
    |> Multi.run(:players, fn
      repo, %{existing: nil} ->
        {count, _rows} = repo.insert_all(player_schema, stamp(rows.players, now))
        {:ok, count}

      _repo, _changes ->
        {:ok, 0}
    end)
    |> Multi.run(:actions, fn
      repo, %{existing: nil} when rows.actions != [] ->
        {count, _rows} = repo.insert_all(HandAction, rows.actions)
        {:ok, count}

      _repo, _changes ->
        {:ok, 0}
    end)
    |> Multi.run(:stats, fn
      repo, %{existing: nil} -> increment_stats(repo, rows.stats, now)
      _repo, _changes -> {:ok, 0}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{existing: nil}} -> {:ok, :written}
      {:ok, _changes} -> {:ok, :already}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp tables(:holdem), do: {HandRecord, HandPlayer}
  defp tables(:ofc), do: {OfcHand, OfcHandPlayer}

  defp stamp(rows, now) do
    Enum.map(rows, fn row ->
      row
      |> Map.put(:id, Ecto.UUID.generate())
      |> Map.put(:inserted_at, now)
      |> Map.put(:updated_at, now)
    end)
  end

  @doc """
  Записать итог турнирного входа. Идемпотентность даёт БД: повтор с тем же
  `entry_id` гасится unique-индексом, а не проверкой в коде — только
  constraint работает при конкурентных ретраях.
  """
  @spec write_tournament_result(map()) :: {:ok, :written | :already} | {:error, term()}
  def write_tournament_result(attrs) do
    %TournamentResult{}
    |> TournamentResult.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, _result} ->
        {:ok, :written}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :entry_id), do: {:ok, :already}, else: {:error, changeset}
    end
  end

  @doc """
  Пометить добровольно открытые карты. Уже открытые по правилам вскрытия
  (`showdown`) не трогаются: их видимость сильнее.
  """
  @spec mark_voluntary(Ecto.UUID.t(), [Ecto.UUID.t()]) :: {:ok, non_neg_integer()}
  def mark_voluntary(_hand_id, []), do: {:ok, 0}

  def mark_voluntary(hand_id, user_ids) do
    {count, _rows} =
      HandPlayer
      |> where([p], p.hand_id == ^hand_id)
      |> where([p], p.user_id in ^user_ids)
      |> where([p], p.card_visibility == :hidden)
      |> Repo.update_all(set: [card_visibility: :voluntary, updated_at: DateTime.utc_now()])

    {:ok, count}
  end

  # --- дневной агрегат -------------------------------------------------------

  # Сырой SQL, а не `insert_all`: нужно сложение (`col = col + new.col`),
  # которого в `on_conflict` Ecto для MySQL нет. Форма с алиасом строки
  # (`AS new`) вместо устаревшей `VALUES()` — она работает начиная с
  # MySQL 8.0.19 и не пишет в лог предупреждение об устаревании.
  defp increment_stats(_repo, [], _now), do: {:ok, 0}

  defp increment_stats(repo, rows, now) do
    counters = PlayerStatsDaily.counters()
    columns = @stat_keys ++ counters ++ [:inserted_at, :updated_at]

    row_placeholder = "(" <> Enum.map_join(columns, ",", fn _column -> "?" end) <> ")"
    placeholders = Enum.map_join(rows, ",", fn _row -> row_placeholder end)

    updates =
      counters
      |> Enum.map_join(", ", fn counter ->
        # Левая часть квалифицируется таблицей: рядом с алиасом строки
        # (`AS new`) голое имя колонки для MySQL неоднозначно.
        "`player_stats_daily`.`#{counter}` = `player_stats_daily`.`#{counter}` + new.`#{counter}`"
      end)
      |> Kernel.<>(", `player_stats_daily`.`updated_at` = new.`updated_at`")

    sql = """
    INSERT INTO `player_stats_daily` (#{Enum.map_join(columns, ",", &"`#{&1}`")})
    VALUES #{placeholders} AS new
    ON DUPLICATE KEY UPDATE #{updates}
    """

    params = Enum.flat_map(rows, &row_params(&1, counters, now))

    case repo.query(sql, params) do
      {:ok, result} -> {:ok, result.num_rows}
      {:error, reason} -> {:error, reason}
    end
  end

  defp row_params(row, counters, now) do
    [
      Ecto.UUID.dump!(row.user_id),
      row.day,
      to_string(row.game_mode),
      Ecto.UUID.dump!(row.setting_id),
      # Валюта в ключе: строка дня своя у каждой шкалы сумм.
      row |> Map.get(:currency, :main) |> to_string()
    ] ++ Enum.map(counters, &Map.get(row, &1, 0)) ++ [now, now]
  end
end
