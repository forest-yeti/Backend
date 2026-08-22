defmodule BlockPoker.Engine.Discipline.Artificial do
  @moduledoc """
  Искусственная дисциплина, существующая только ради проверки шва.

  В неё нельзя играть, и в этом весь смысл: здесь нет ни улиц, ни борда, ни
  торговли, ни банка, ни вскрытия. Раздача — один круг, каждый ходит ровно
  раз единственным действием `:pass` и передаёт фишку соседу слева. Круг
  замкнут, поэтому суммарное число фишек не меняется.

  Если `TableServer` проводит такую раздачу от начала до конца, ни разу не
  узнав, что перед ним, — шов `Engine.Discipline` настоящий. Если где-то в
  оболочке осталось допущение холдема (улица, банк, карманные карты, фолд
  по тайм-ауту), этот стол на нём и споткнётся.

  Модуль намеренно не реализует ни одного необязательного коллбэка: у
  дисциплины нет ни показа карт, ни rabbit hunting, ни двух прогонов, ни
  показателей сессии, — и оболочка обязана обойтись без них молча.
  """

  @behaviour BlockPoker.Engine.Discipline

  alias BlockPoker.Engine.HandSetup

  defstruct [:order, :players, :to_act, seq: 0, passed: []]

  @impl true
  def id, do: :artificial

  @impl true
  def min_players, do: 2

  @impl true
  def max_players, do: 10

  @impl true
  def start(%HandSetup{} = setup, _rng, _opts) do
    order = setup.players |> Enum.map(& &1.seat) |> Enum.sort()

    players =
      Map.new(setup.players, fn player ->
        {player.seat, %{id: player.id, stack: player.stack, total: player.stack}}
      end)

    hand = %__MODULE__{order: order, players: players, to_act: hd(order)}

    {hand, [{:hand_dealt, %{seats: order}}]}
  end

  @impl true
  def act(%__MODULE__{to_act: nil}, _seat, _action, _seq), do: {:error, :hand_finished}

  def act(%__MODULE__{to_act: seat, seq: seq} = hand, seat, :pass, action_seq)
      when action_seq in [nil, seq] do
    {:ok, pass(hand, seat), [{:passed, %{seat: seat}}]}
  end

  def act(%__MODULE__{to_act: seat}, seat, :pass, _stale), do: {:error, :stale_action}

  def act(%__MODULE__{}, _seat, :pass, _seq), do: {:error, :not_your_turn}
  def act(%__MODULE__{}, _seat, _action, _seq), do: {:error, :illegal_action}

  @impl true
  def timeout(%__MODULE__{to_act: nil}), do: {:error, :no_action}
  def timeout(%__MODULE__{to_act: seat} = hand), do: act(hand, seat, :pass, nil)

  @impl true
  def legal_actions(%__MODULE__{to_act: seat}, seat), do: %{pass: true}
  def legal_actions(%__MODULE__{}, _seat), do: %{}

  @impl true
  def to_act(%__MODULE__{to_act: seat}), do: seat

  @impl true
  def seq(%__MODULE__{seq: seq}), do: seq

  @impl true
  def players(%__MODULE__{players: players}), do: players

  @impl true
  def progress(%__MODULE__{to_act: nil}), do: :finished
  def progress(%__MODULE__{}), do: :acting

  @impl true
  def results(%__MODULE__{players: players}) do
    %{stacks: Map.new(players, fn {seat, player} -> {seat, player.stack} end)}
  end

  @impl true
  def public_view(%__MODULE__{} = hand) do
    %{
      to_act: hand.to_act,
      action_seq: hand.seq,
      passed: hand.passed,
      seats: Map.new(hand.players, fn {seat, player} -> {seat, %{stack: player.stack}} end)
    }
  end

  @impl true
  def private_view(%__MODULE__{} = hand, seat) do
    case Map.get(hand.players, seat) do
      nil -> nil
      player -> %{stack: player.stack, legal_actions: legal_actions(hand, seat)}
    end
  end

  # Фишка уходит соседу слева. Последний в круге отдаёт первому, поэтому
  # сумма фишек за столом не меняется — тот же инвариант, что и у банка.
  defp pass(%__MODULE__{} = hand, seat) do
    next = next_seat(hand.order, seat)

    players =
      hand.players
      |> Map.update!(seat, &%{&1 | stack: &1.stack - 1})
      |> Map.update!(next, &%{&1 | stack: &1.stack + 1})

    passed = hand.passed ++ [seat]
    done? = length(passed) == length(hand.order)

    %{
      hand
      | players: players,
        passed: passed,
        seq: hand.seq + 1,
        to_act: if(done?, do: nil, else: next)
    }
  end

  defp next_seat(order, seat) do
    case Enum.drop_while(order, &(&1 != seat)) do
      [^seat, next | _rest] -> next
      _last -> hd(order)
    end
  end
end
