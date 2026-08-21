defmodule BlockPoker.Engine.BlindSchedule do
  @moduledoc """
  Структура уровней турнира: какие номиналы действуют сейчас и когда сменятся.

  Уровень несёт **три** номинала — малый блайнд, большой блайнд и анте, —
  а не два, потому что вид покера решает, что из них живое: холдем играется
  на блайндах, Short Deck — на анте кнопки, где блайндов нет вовсе
  (`BettingStructure.ButtonAnte`). Расписание не выбирает между ними и не
  знает про виды игры: оно отдаёт три числа, а читает нужные структура
  ставок. Поэтому одна и та же таблица описывает обе дисциплины, и `case`
  по варианту здесь не появляется.

  ## Что происходит, когда уровни кончились

  Действует последний. Турнир обязан заканчиваться победителем, а не концом
  таблицы, и «дальше играем на том же» — единственное поведение, которое
  не требует от оператора заводить уровни на все случаи жизни. Гипер-структура
  к последнему уровню всё равно съедает стеки за считанные раздачи.

  ## Время

  Уровень живёт `duration_seconds` **реального времени**, а не раздач:
  игрок договаривается с румом в минутах, и длительность раздачи зависит
  от того, сколько народу осталось. Смена уровня, однако, применяется
  **между раздачами**: поднимать блайнды посреди улицы нельзя — это меняет
  цену уже принятого решения.

  Модуль чистый: список уровней и номер на входе, номиналы на выходе.
  Часы сюда не приходят, дедлайн считает тот, кто ими владеет.
  """

  @typedoc "Один уровень структуры."
  @type level :: %{
          level: pos_integer(),
          small_blind: non_neg_integer(),
          big_blind: non_neg_integer(),
          ante: non_neg_integer(),
          duration_seconds: pos_integer()
        }

  @doc """
  Уровень с номером `number`. Номера за пределами таблицы отдают последний —
  см. «что происходит, когда уровни кончились».
  """
  @spec at([level()], pos_integer()) :: level()
  def at([], _number), do: raise(ArgumentError, "пустая структура уровней")

  def at(levels, number) when number >= 1 do
    case Enum.find(levels, &(&1.level == number)) do
      nil -> last(levels)
      level -> level
    end
  end

  @doc "Первый уровень: с него турнир начинается."
  @spec first([level()]) :: level()
  def first(levels), do: at(levels, 1)

  @doc "Последний заведённый уровень."
  @spec last([level()]) :: level()
  def last([]), do: raise(ArgumentError, "пустая структура уровней")
  def last(levels), do: Enum.max_by(levels, & &1.level)

  @doc """
  Есть ли куда расти. `false` означает, что номиналы больше не изменятся —
  и таймер уровня можно не заводить вовсе.
  """
  @spec next?([level()], pos_integer()) :: boolean()
  def next?(levels, number), do: number < last(levels).level

  @doc """
  Сколько миллисекунд длится уровень. Отдельная функция, потому что
  расписание хранит секунды (так его читает человек), а таймеры стола
  живут в миллисекундах.
  """
  @spec duration_ms([level()], pos_integer()) :: pos_integer()
  def duration_ms(levels, number), do: at(levels, number).duration_seconds * 1000

  @doc """
  Номиналы уровня в виде, который понимает `BettingStructure.bet_unit/1`.
  Нужен комнате до начала раздачи — например, чтобы назвать цену круга
  в витрине лобби.
  """
  @spec limits(level()) :: %{big_blind: non_neg_integer(), ante: non_neg_integer()}
  def limits(%{big_blind: big_blind, ante: ante}), do: %{big_blind: big_blind, ante: ante}

  @doc """
  Расписание словами для одной строки экрана: «50/100» на блайндах,
  «анте 100» на анте кнопки. Выбор делается по номиналам, а не по виду
  игры, — тем же способом, каким его делает структура ставок.
  """
  @spec label(level()) :: String.t()
  def label(%{big_blind: 0, ante: ante}), do: "анте #{ante}"

  def label(%{small_blind: small, big_blind: big, ante: 0}), do: "#{small}/#{big}"

  def label(%{small_blind: small, big_blind: big, ante: ante}),
    do: "#{small}/#{big} (#{ante})"
end
