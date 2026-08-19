defmodule BlockPoker.Engine.RunItTwice do
  @moduledoc """
  Согласие на два прогона борда: кого спрашивают, кто как ответил, чем
  кончилось.

  Модуль ничего не сдаёт и не считает деньги. Он отвечает на один вопрос —
  **договорились ли**, — и на этом его полномочия кончаются: борды сдаёт
  `Hand`, банк делит `Hand`, а сколько прогонов получилось, видно по числу
  бордов, а не по флагу здесь.

  Правила согласия жёсткие и намеренно скучные:

    * спрашивают ровно двоих — тех, кто дошёл до доводки;
    * согласие нужно от обоих, отказ одного закрывает вопрос немедленно
      (ждать второго ответа незачем);
    * **молчание — отказ.** Не ответивший к закрытию окна считается
      отказавшимся: подвесить стол ожиданием нельзя, а списать игроку
      половину банка за молчание — тем более.

  Структура чистая: ни таймеров, ни процессов. Время живёт снаружи, в
  `TableServer`, и приходит сюда единственным событием — `close/1`.
  """

  @type seat :: pos_integer()
  @type status :: :offered | :accepted | :declined

  @type t :: %__MODULE__{
          seats: [seat()],
          answers: %{seat() => boolean()},
          status: status()
        }

  @enforce_keys [:seats]
  defstruct seats: [], answers: %{}, status: :offered

  @doc "Открыть вопрос двоим претендентам."
  @spec offer([seat()]) :: t()
  def offer([_first, _second] = seats), do: %__MODULE__{seats: Enum.sort(seats)}

  @doc "Ждёт ли раздача ответа прямо сейчас."
  @spec offered?(t() | nil) :: boolean()
  def offered?(%__MODULE__{status: :offered}), do: true
  def offered?(_other), do: false

  @doc """
  Ответ одного игрока.

  Закрывает вопрос сам, как только исход определён: согласие обоих или
  первый же отказ. Пока исход не определён — остаётся `:offered`.
  """
  @spec answer(t() | nil, seat(), boolean()) ::
          {:ok, t()} | {:error, :run_it_twice_not_offered | :not_a_contender | :already_answered}
  def answer(nil, _seat, _accept?), do: {:error, :run_it_twice_not_offered}

  def answer(%__MODULE__{status: status}, _seat, _accept?) when status != :offered,
    do: {:error, :run_it_twice_not_offered}

  def answer(%__MODULE__{} = rit, seat, accept?) do
    cond do
      seat not in rit.seats -> {:error, :not_a_contender}
      Map.has_key?(rit.answers, seat) -> {:error, :already_answered}
      true -> {:ok, settle(%{rit | answers: Map.put(rit.answers, seat, accept?)})}
    end
  end

  @doc """
  Закрыть вопрос снаружи: время вышло. Неотвеченное — отказ.
  """
  @spec close(t()) :: t()
  def close(%__MODULE__{status: :offered} = rit), do: %{rit | status: outcome(rit)}
  def close(%__MODULE__{} = rit), do: rit

  @doc "Договорились ли играть дважды."
  @spec accepted?(t() | nil) :: boolean()
  def accepted?(%__MODULE__{status: :accepted}), do: true
  def accepted?(_other), do: false

  # Исход определён, когда кто-то отказался или ответили оба. До тех пор
  # вопрос остаётся открытым.
  defp settle(%__MODULE__{} = rit) do
    answered? = map_size(rit.answers) == length(rit.seats)
    refused? = Enum.any?(Map.values(rit.answers), &(&1 == false))

    if answered? or refused?, do: %{rit | status: outcome(rit)}, else: rit
  end

  defp outcome(%__MODULE__{} = rit) do
    if map_size(rit.answers) == length(rit.seats) and Enum.all?(Map.values(rit.answers)),
      do: :accepted,
      else: :declined
  end
end
