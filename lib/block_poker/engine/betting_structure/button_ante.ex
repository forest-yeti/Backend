defmodule BlockPoker.Engine.BettingStructure.ButtonAnte do
  @moduledoc """
  Анте от всех плюс дополнительное анте кнопки — структура Short Deck
  в том виде, в каком её играют GGPoker и живые турниры Triton.

  Каждую раздачу все участники платят анте, а кнопка платит второе. Именно
  второе анте кнопки — **живая** ставка: её уравнивают, чтобы увидеть флоп.
  Обычные анте мёртвые: они лежат в банке и ничьей ставкой не являются.

  Отсюда порядок хода: первым говорит игрок слева от кнопки, кнопка —
  последней. И на префлопе, и после него: позиция за столом одна и та же
  на всех улицах, в отличие от блайндов, где до флопа последним говорит
  большой блайнд. Право последнего слова кнопка сохраняет и когда все
  уравняли — как большой блайнд в холдеме.

  Экономический смысл структуры — в §10 задачи 4: анте создаёт банк, ради
  которого стоит играть, размазывает плату за круг по всем местам поровну
  и продаёт лучшую позицию за деньги, вместо того чтобы облагать две
  худшие.

  Хедз-ап отдельным случаем не является: оба платят анте, кнопка платит
  второе и говорит последней. Ничего менять местами, как блайнды в
  холдеме, здесь не нужно.
  """

  @behaviour BlockPoker.Engine.BettingStructure

  alias BlockPoker.Engine.EntryRules
  alias BlockPoker.Engine.HandSetup

  @impl true
  def id, do: :button_ante

  @impl true
  def bet_unit(%{ante: ante}), do: ante

  # Ждать нечего: анте платят все и каждую раздачу, уклониться от своей
  # очереди платить невозможно — очереди нет.
  @impl true
  def entry_rules, do: EntryRules.Immediate

  @impl true
  def last_to_act_preflop(%HandSetup{} = setup), do: setup |> seats() |> button_seat(setup)

  @impl true
  def forced_bets(%HandSetup{ante: ante} = setup) do
    seats = seats(setup)
    button = button_seat(seats, setup)

    antes = Enum.map(seats, &%{seat: &1, kind: :ante, amount: ante, live?: false})

    antes ++ [%{seat: button, kind: :button_ante, amount: ante, live?: true}]
  end

  defp seats(setup), do: setup |> HandSetup.order_from_button() |> Enum.map(& &1.seat)

  # Кнопка может стоять на месте, которое раздачу не играет («мёртвая
  # кнопка»): платить второе анте тогда некому, и его берёт на себя первый
  # в круге — тот, кто в этой раздаче и есть ближайший к кнопке.
  defp button_seat(seats, %HandSetup{button_seat: button}) do
    if button in seats, do: button, else: List.last(seats)
  end
end
