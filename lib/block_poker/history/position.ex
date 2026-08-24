defmodule BlockPoker.History.Position do
  @moduledoc """
  Позиция игрока в раздаче по номеру места и кнопке.

  Доменное знание, и живёт оно в ядре: `api/` не имеет права его считать
  (§3 CLAUDE.md), а раздача в нём не нуждается — движку всё равно, как
  называется место, ему важен только порядок хода.

  Считается по **фактическому составу раздачи**, а не по вместимости
  стола: за девятимаксным столом впятером играют пятимаксные позиции.
  Хедз-ап — отдельная строка таблицы, а не частный случай: кнопка там
  совпадает с малым блайндом, и `sb` в раздаче не существует вовсе.
  """

  @tables %{
    2 => [:btn, :bb],
    3 => [:btn, :sb, :bb],
    4 => [:btn, :sb, :bb, :utg],
    5 => [:btn, :sb, :bb, :utg, :co],
    6 => [:btn, :sb, :bb, :utg, :hj, :co],
    7 => [:btn, :sb, :bb, :utg, :lj, :hj, :co],
    8 => [:btn, :sb, :bb, :utg, :utg1, :lj, :hj, :co],
    9 => [:btn, :sb, :bb, :utg, :utg1, :utg2, :lj, :hj, :co],
    10 => [:btn, :sb, :bb, :utg, :utg1, :utg2, :mp, :lj, :hj, :co]
  }

  @doc """
  Позиции всех мест раздачи: `%{seat => position}`.

  `nil` вместо кнопки или состав, которого нет в таблице, дают пустую
  карту, а не падение: история пишется после раздачи, и уронить её запись
  из-за незнакомого состава нельзя.
  """
  @spec for_seats([pos_integer()], pos_integer() | nil) :: %{pos_integer() => atom()}
  def for_seats(seats, button_seat)

  def for_seats(_seats, nil), do: %{}

  def for_seats(seats, button_seat) do
    seats = Enum.sort(seats)

    case Map.fetch(@tables, length(seats)) do
      {:ok, names} ->
        seats
        |> rotate_to(button_seat)
        |> Enum.zip(names)
        |> Map.new()

      :error ->
        %{}
    end
  end

  # Кнопка встаёт первой, дальше по кругу. Кнопка на месте, которое
  # раздачу не играет, — это состояние, из которого стол раздачу не
  # начинает, но проверить дешевле, чем доказать.
  defp rotate_to(seats, button_seat) do
    case Enum.find_index(seats, &(&1 == button_seat)) do
      nil -> seats
      index -> Enum.drop(seats, index) ++ Enum.take(seats, index)
    end
  end
end
