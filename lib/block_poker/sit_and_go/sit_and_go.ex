defmodule BlockPoker.SitAndGo do
  @moduledoc """
  Контекст Sit & Go: шаблоны турниров, их структуры уровней и таблицы призов.

  Наружу отдаёт **готовые к игре** значения: расписание уровней в виде,
  который понимает `Engine.BlindSchedule`, и таблицу тиров в виде, который
  понимает `Engine.PrizePool`. Транспорт и комната работают с ними, а
  не со схемами Ecto.

  Здесь же живёт проверка экономики (`audit/1`): свойство таблицы призов —
  что она возвращает игрокам заданную долю взносов — проверяется по набору
  строк целиком, и потому не может быть выражено ни constraint'ом БД, ни
  changeset'ом одной строки.
  """

  import Ecto.Query

  alias BlockPoker.Engine.{BlindSchedule, PrizePool}
  alias BlockPoker.Repo
  alias BlockPoker.SitAndGo.{BlindLevel, PrizeTier, SitAndGoSetting}
  alias Ecto.Multi

  @typedoc """
  Фильтр витрины. `game_types: []` означает «все» — пустой список фильтром
  не является, иначе экран с ничем не отмеченным фильтром показывал бы
  пустое лобби вместо всего пула.
  """
  @type filter :: [game_types: [atom()], currency: :main | :play_money, enabled: boolean()]

  @doc """
  Шаблоны для витрины, отсортированные так, как их показывает лобби.

  Уровни и тиры подгружаются сразу: комната читает шаблон один раз при
  старте и больше в БД за ним не ходит (§8 задачи 3), а витрине нужен
  первый уровень и старший множитель.
  """
  @spec list_settings(filter()) :: [SitAndGoSetting.t()]
  def list_settings(filter \\ []) do
    SitAndGoSetting
    |> filter_enabled(Keyword.get(filter, :enabled, true))
    |> filter_game_types(Keyword.get(filter, :game_types, []))
    |> filter_currency(Keyword.get(filter, :currency))
    |> preload([:blind_levels, :prize_tiers])
    |> Repo.all()
    # Порядок задаётся в Elixir, а не в SQL: разряд валюты — доменное
    # правило, а не алфавит. `ORDER BY currency` работал бы сегодня по
    # случайности (main < play_money как строки) и молча сломался бы на
    # первой же валюте, чьё имя встало не туда.
    |> Enum.sort_by(&SitAndGoSetting.sort_key/1)
  end

  @spec get_setting(Ecto.UUID.t()) :: {:ok, SitAndGoSetting.t()} | {:error, :not_found}
  def get_setting(id) do
    case SitAndGoSetting |> preload([:blind_levels, :prize_tiers]) |> Repo.get(id) do
      nil -> {:error, :not_found}
      setting -> {:ok, setting}
    end
  end

  @doc "Расписание уровней шаблона в виде, который читает `Engine.BlindSchedule`."
  @spec blind_schedule(SitAndGoSetting.t()) :: [BlindSchedule.level()]
  def blind_schedule(%SitAndGoSetting{blind_levels: levels}) when is_list(levels) do
    levels |> Enum.sort_by(& &1.level) |> Enum.map(&BlindLevel.to_schedule/1)
  end

  @doc "Таблица призов шаблона в виде, который читает `Engine.PrizePool`."
  @spec prize_table(SitAndGoSetting.t()) :: [PrizePool.tier()]
  def prize_table(%SitAndGoSetting{prize_tiers: tiers}) when is_list(tiers) do
    tiers |> Enum.sort_by(& &1.multiplier) |> Enum.map(&PrizeTier.to_tier/1)
  end

  @doc """
  Создаёт шаблон вместе с его уровнями и тирами одной транзакцией.

  Целиком или никак: шаблон без структуры уровней не запускается, а без
  таблицы призов не может закончиться выплатой — половина строк в БД
  была бы не «частично готовым турниром», а сломанным.
  """
  @spec create_setting(map(), [map()], [map()]) ::
          {:ok, SitAndGoSetting.t()} | {:error, atom() | Ecto.Changeset.t()}
  def create_setting(attrs, levels, tiers) do
    Multi.new()
    |> Multi.insert(:setting, SitAndGoSetting.changeset(%SitAndGoSetting{}, attrs))
    |> Multi.run(:levels, fn repo, %{setting: setting} ->
      insert_all(repo, setting, levels, &BlindLevel.changeset(%BlindLevel{}, &1))
    end)
    |> Multi.run(:tiers, fn repo, %{setting: setting} ->
      insert_all(repo, setting, tiers, &PrizeTier.changeset(%PrizeTier{}, &1))
    end)
    |> Multi.run(:audit, fn _repo, %{setting: setting, tiers: tiers} ->
      audit_tiers(setting, Enum.map(tiers, &PrizeTier.to_tier/1))
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{setting: setting}} -> get_setting(setting.id)
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Проверка шаблона целиком — то, что нельзя выразить ни одной строкой.

  Три свойства:

    * шансы таблицы складываются ровно в `PrizePool.chance_scale/0`;
    * ни один тир не оплачивает мест больше, чем игроков за столом;
    * структура уровней непуста и начинается с первого.

  Возврат игроку (`return_ppm`) отдаётся числом, а не сверяется с порогом:
  «правильного» RTP не существует, это решение оператора. Порог проверяет
  тест сетки, которому известно, о чём договаривались.
  """
  @spec audit(SitAndGoSetting.t()) ::
          {:ok, %{return_ppm: non_neg_integer(), expected_multiplier_ppm: non_neg_integer()}}
          | {:error, atom()}
  def audit(%SitAndGoSetting{} = setting) do
    with :ok <- audit_levels(setting),
         {:ok, _tiers} <- audit_tiers(setting, prize_table(setting)) do
      tiers = prize_table(setting)

      {:ok,
       %{
         return_ppm: PrizePool.expected_return_ppm(tiers, setting.max_players),
         expected_multiplier_ppm: PrizePool.expected_multiplier_ppm(tiers)
       }}
    end
  end

  defp audit_levels(%SitAndGoSetting{} = setting) do
    case blind_schedule(setting) do
      [] -> {:error, :no_blind_levels}
      levels -> if Enum.any?(levels, &(&1.level == 1)), do: :ok, else: {:error, :no_first_level}
    end
  end

  defp audit_tiers(%SitAndGoSetting{} = setting, tiers) do
    cond do
      tiers == [] ->
        {:error, :no_prize_tiers}

      not PrizePool.valid_chances?(tiers) ->
        {:error, :chances_do_not_sum}

      Enum.any?(tiers, &(length(&1.payouts) > setting.max_players)) ->
        {:error, :too_many_paid_places}

      true ->
        {:ok, tiers}
    end
  end

  defp insert_all(repo, setting, rows, to_changeset) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      row
      |> Map.put(:sit_n_go_setting_id, setting.id)
      |> to_changeset.()
      |> Ecto.Changeset.put_change(:sit_n_go_setting_id, setting.id)
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

  defp filter_enabled(query, nil), do: query
  defp filter_enabled(query, enabled), do: where(query, [s], s.enabled == ^enabled)

  defp filter_game_types(query, []), do: query
  defp filter_game_types(query, nil), do: query
  defp filter_game_types(query, types), do: where(query, [s], s.game_type in ^types)

  defp filter_currency(query, nil), do: query
  defp filter_currency(query, currency), do: where(query, [s], s.currency == ^currency)
end
