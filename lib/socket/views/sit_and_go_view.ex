defmodule Socket.Views.SitAndGoView do
  @moduledoc """
  Витрина Sit & Go: шаблоны турниров с их структурами и таблицами призов.

  Транспорт, а не логика: решает, *какие* поля показать, но не вычисляет
  доменных значений. Множители приходят и числом, и готовой подписью —
  делить сотые доли на разы это арифметика над доменным значением, и её
  место в ядре (§3 CLAUDE.md).
  """

  alias BlockPoker.Engine.{BlindSchedule, PrizePool}
  alias BlockPoker.SitAndGo
  alias BlockPoker.SitAndGo.SitAndGoSetting

  @doc """
  Полная витрина: список шаблонов и словарь доступных дисциплин.

  Дисциплины отдаются сервером, а не зашиты в клиент: добавление нового
  вида покера не должно требовать релиза Electron.
  """
  @spec render([map()]) :: %{tournaments: [map()], filters: map()}
  def render(snapshot) do
    %{tournaments: Enum.map(snapshot, &setting/1), filters: %{game_types: game_types()}}
  end

  @spec setting(map()) :: map()
  def setting(%{setting: setting, registered: registered, running: running}) do
    %{
      setting_id: setting.id,
      name: setting.name,
      game_type: setting.game_type,
      currency: setting.currency,
      betting_structure: SitAndGoSetting.structure(setting).id(),
      # Взнос — в минимальных единицах валюты, стек — в фишках. Это разные
      # величины и разные шкалы: турнирная фишка деньгами не является.
      buy_in: setting.buy_in,
      starting_stack: setting.starting_stack,
      max_players: setting.max_players,
      # Сколько уже зарегистрировано в тот турнир, куда посадит вход.
      registered: registered,
      # Сколько турниров этого шаблона идёт прямо сейчас.
      running: running,
      blind_levels: Enum.map(SitAndGo.blind_schedule(setting), &level/1),
      prize_tiers: Enum.map(SitAndGo.prize_table(setting), &tier/1),
      visuals: %{felt_color: setting.felt_color, background_color: setting.background_color}
    }
  end

  @doc """
  Один уровень структуры. Подпись приходит готовой: выбирать между
  «50/100» и «анте 100» — это знание о том, какая структура ставок у
  какой дисциплины, и клиенту его иметь незачем.
  """
  @spec level(BlindSchedule.level()) :: map()
  def level(level) do
    %{
      level: level.level,
      small_blind: level.small_blind,
      big_blind: level.big_blind,
      ante: level.ante,
      duration_seconds: level.duration_seconds,
      label: BlindSchedule.label(level)
    }
  end

  @doc """
  Один призовой тир. Шанс уходит в миллионных долях числом — клиент рисует
  по нему шкалу барабана, а не считает вероятности.
  """
  @spec tier(PrizePool.tier()) :: map()
  def tier(tier) do
    %{
      multiplier: tier.multiplier,
      label: PrizePool.multiplier_label(tier.multiplier),
      chance_ppm: tier.chance_ppm,
      payouts: tier.payouts
    }
  end

  defp game_types, do: BlockPoker.Engine.Variant.Registry.ids()
end
