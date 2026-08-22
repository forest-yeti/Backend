defprotocol BlockPoker.Tables.Blueprint do
  @moduledoc """
  Шаблон стола глазами лобби: всё, что нужно, чтобы поднять из строки БД
  комнату и показать её в витрине.

  Протокол существует ради того же, ради чего `Engine.Discipline` и
  `GameMode`: чтобы ветвления по типу стола не было. Лобби не спрашивает,
  кэш перед ним или китайский покер, — оно спрашивает «сколько комнат
  разворачивать», «с каким режимом и дисциплиной их поднимать» и «в какой
  раздел витрины они идут». Отвечает шаблон.

  `category/1` — единственное место, где типы столов вообще названы. Она
  не про правила: OFC по движению денег такой же кэш, — она про **витрину**.
  Столы китайского покера в общую сетку холдема не подмешиваются, у них
  свой топик лобби, и категория и есть ответ на вопрос «чей это раздел».
  """

  @typedoc "Раздел витрины. Не тип игры, а раздел: у каждого свой топик лобби."
  @type category :: :cash | :ofc

  @doc "Раздел витрины, к которому шаблон относится."
  @spec category(t()) :: category()
  def category(setting)

  @doc "Разворачивать ли из шаблона комнаты вообще."
  @spec enabled?(t()) :: boolean()
  def enabled?(setting)

  @doc "Виден ли шаблон в общей сетке лобби. У закрытой комнаты — нет."
  @spec public?(t()) :: boolean()
  def public?(setting)

  @doc "Сколько комнат шаблон разворачивает максимум."
  @spec room_limit(t()) :: pos_integer()
  def room_limit(setting)

  @doc "Вместимость стола."
  @spec max_players(t()) :: pos_integer()
  def max_players(setting)

  @doc """
  Базовая единица стола: большой блайнд у блайндового, анте у анте-стола,
  стоимость очка у китайского покера. В ней считается лимит витрины.
  """
  @spec bet_unit(t()) :: non_neg_integer()
  def bet_unit(setting)

  @doc "Вид покера — по нему собирается колода и роспись пятёрки."
  @spec game_type(t()) :: atom()
  def game_type(setting)

  @doc "Валюта стола. Она же задаёт разделы витрины внутри категории."
  @spec currency(t()) :: atom()
  def currency(setting)

  @doc "Подпись стола в лобби."
  @spec display_name(t()) :: String.t()
  def display_name(setting)

  @doc """
  Чем поднимать комнату: режим и дисциплина. Ровно эти два модуля и
  отличают стол китайского покера от кэш-стола — всё остальное в оболочке
  у них общее.
  """
  @spec room_opts(t()) :: keyword()
  def room_opts(setting)
end

defimpl BlockPoker.Tables.Blueprint, for: BlockPoker.CashGames.CashGameSetting do
  alias BlockPoker.CashGames.CashGameSetting

  def category(_setting), do: :cash
  def enabled?(setting), do: setting.enabled
  def public?(setting), do: CashGameSetting.public?(setting)
  def room_limit(setting), do: CashGameSetting.room_limit(setting)
  def max_players(setting), do: setting.max_players
  def bet_unit(setting), do: CashGameSetting.bet_unit(setting)
  def game_type(setting), do: setting.game_type
  def currency(setting), do: setting.currency
  def display_name(setting), do: CashGameSetting.display_name(setting)

  def room_opts(_setting) do
    [game_mode: BlockPoker.GameMode.Cash, discipline: BlockPoker.Engine.Hand]
  end
end

defimpl BlockPoker.Tables.Blueprint, for: BlockPoker.OfcGames.OfcSetting do
  alias BlockPoker.OfcGames.OfcSetting

  def category(_setting), do: :ofc
  def enabled?(setting), do: setting.enabled
  def public?(setting), do: OfcSetting.public?(setting)
  def room_limit(setting), do: OfcSetting.room_limit(setting)
  def max_players(setting), do: setting.max_players
  def bet_unit(setting), do: OfcSetting.bet_unit(setting)
  def game_type(setting), do: setting.game_type
  def currency(setting), do: setting.currency
  def display_name(setting), do: BlockPoker.GameMode.OfcCash.name(setting)

  def room_opts(_setting) do
    [game_mode: BlockPoker.GameMode.OfcCash, discipline: BlockPoker.Engine.Ofc.Hand]
  end
end
