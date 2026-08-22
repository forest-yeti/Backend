defmodule BlockPoker.Engine.Ofc.Board do
  @moduledoc """
  Раскладка одного игрока: три бокса и правило их порядка.

  Бокс — это список карт с потолком вместимости: `top` держит три карты,
  `middle` и `bottom` — по пять. Выложенная карта не двигается и не
  снимается, поэтому размещение здесь только добавляет.

  Рука обязана усиливаться сверху вниз: `bottom >= middle >= top`. Нарушение
  — фол, и он проверяется **только по завершении раскладки**: у недособранной
  руки сравнивать нечего, а объявлять её мёртвой раньше времени значило бы
  запретить игроку планировать.

  Сравнение боксов идёт по одной шкале силы (`HandRank`), поэтому правило
  выражается обычным `>=` и второй таблицы не требует.
  """

  alias BlockPoker.Engine.{Card, HandRank}
  alias BlockPoker.Engine.Ofc.TopRank

  @rows [:top, :middle, :bottom]
  @capacity %{top: 3, middle: 5, bottom: 5}

  @type row :: :top | :middle | :bottom

  @type t :: %__MODULE__{top: [Card.t()], middle: [Card.t()], bottom: [Card.t()]}

  defstruct top: [], middle: [], bottom: []

  @doc "Порядок боксов сверху вниз. Единственный источник их списка."
  @spec rows() :: [row()]
  def rows, do: @rows

  @doc """
  Бокс по имени. Имя приходит с клиента строкой и превращается в бокс
  **здесь**: список рядов принадлежит дисциплине, и второй его копии в
  транспорте быть не должно.
  """
  @spec fetch_row(term()) :: {:ok, row()} | :error
  def fetch_row(row) when row in @rows, do: {:ok, row}

  def fetch_row(row) when is_binary(row) do
    case Enum.find(@rows, &(Atom.to_string(&1) == row)) do
      nil -> :error
      found -> {:ok, found}
    end
  end

  def fetch_row(_row), do: :error

  @doc "Вместимость бокса в картах."
  @spec capacity(row()) :: pos_integer()
  def capacity(row) when row in @rows, do: Map.fetch!(@capacity, row)

  @doc "Пустая раскладка."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Сколько карт уже выложено."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{} = board), do: Enum.sum(Enum.map(@rows, &length(cards(board, &1))))

  @doc "Карты бокса в порядке выкладывания."
  @spec cards(t(), row()) :: [Card.t()]
  def cards(%__MODULE__{} = board, row) when row in @rows, do: Map.fetch!(board, row)

  @doc "Все выложенные карты одним списком."
  @spec all_cards(t()) :: [Card.t()]
  def all_cards(%__MODULE__{} = board), do: Enum.flat_map(@rows, &cards(board, &1))

  @doc "Собрана ли рука целиком: тринадцать карт по своим боксам."
  @spec complete?(t()) :: boolean()
  def complete?(%__MODULE__{} = board), do: Enum.all?(@rows, &full?(board, &1))

  @doc "Сколько карт бокс ещё примет."
  @spec free(t(), row()) :: non_neg_integer()
  def free(%__MODULE__{} = board, row), do: capacity(row) - length(cards(board, row))

  @doc """
  Размещение карт по боксам одним ходом.

  Ход проверяется **целиком**: частичных размещений не бывает, и раскладка
  либо принимается вся, либо не меняется вовсе. Отвергается размещение в
  переполненный бокс и в несуществующий ряд; принадлежность карт сдаче
  проверяет раздача — боксу неоткуда знать, что игроку сдавали.
  """
  @spec place(t(), [{Card.t(), row() | String.t()}]) :: {:ok, t()} | {:error, :invalid_placement}
  def place(%__MODULE__{} = board, placements) when is_list(placements) do
    Enum.reduce_while(placements, {:ok, board}, fn placement, {:ok, acc} ->
      case put(acc, placement) do
        {:ok, next} -> {:cont, {:ok, next}}
        :error -> {:halt, {:error, :invalid_placement}}
      end
    end)
  end

  def place(%__MODULE__{}, _placements), do: {:error, :invalid_placement}

  defp put(board, {card, row}) do
    with {:ok, row} <- fetch_row(row),
         true <- free(board, row) > 0 and Card.valid?(card) do
      {:ok, Map.update!(board, row, &(&1 ++ [card]))}
    else
      _other -> :error
    end
  end

  defp put(_board, _placement), do: :error

  @doc """
  Роспись бокса. Верхний считается по своим правилам (три карты, без стритов
  и флешей), средний и нижний — обычной пятикарточной росписью варианта.

  `nil` — бокс ещё не собран: неполную руку не оценивают.
  """
  @spec rank(t(), row(), module() | HandRank.Context.t()) :: HandRank.t() | nil
  def rank(%__MODULE__{} = board, row, context) do
    cards = cards(board, row)

    cond do
      length(cards) < capacity(row) -> nil
      row == :top -> TopRank.evaluate(cards, context)
      true -> HandRank.best_of_five(cards, context)
    end
  end

  @doc """
  Мёртвая ли рука. Собранная раскладка обязана усиливаться сверху вниз;
  несобранная фолом быть не может — её ещё не с чем сравнивать.
  """
  @spec foul?(t(), module() | HandRank.Context.t()) :: boolean()
  def foul?(%__MODULE__{} = board, context) do
    if complete?(board) do
      top = rank(board, :top, context)
      middle = rank(board, :middle, context)
      bottom = rank(board, :bottom, context)

      middle.score < top.score or bottom.score < middle.score
    else
      false
    end
  end

  @doc """
  Заведомо мёртвая ли рука — по тому, что уже выложено.

  От `foul?/2` отличается тем, что не ждёт конца раскладки: если два соседних
  бокса **уже собраны** и стоят в неверном порядке, доложить остальное так,
  чтобы рука ожила, невозможно. Нужна автораскладке: она обязана отбрасывать
  такие ветки, а не узнавать о фоле в конце.
  """
  @spec dead?(t(), module() | HandRank.Context.t()) :: boolean()
  def dead?(%__MODULE__{} = board, context) do
    ranks = Map.new(@rows, &{&1, rank(board, &1, context)})

    weaker?(ranks[:middle], ranks[:top]) or weaker?(ranks[:bottom], ranks[:middle]) or
      weaker?(ranks[:bottom], ranks[:top])
  end

  defp weaker?(nil, _than), do: false
  defp weaker?(_rank, nil), do: false
  defp weaker?(rank, than), do: rank.score < than.score

  defp full?(board, row), do: length(cards(board, row)) == capacity(row)
end
