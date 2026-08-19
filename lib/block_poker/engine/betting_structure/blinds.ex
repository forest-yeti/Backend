defmodule BlockPoker.Engine.BettingStructure.Blinds do
  @moduledoc """
  Классическая структура: малый и большой блайнды, при желании — анте.

  Поведение перенесено из `Engine.Hand` дословно, включая два неочевидных
  случая, за каждым из которых стоит починенный баг:

    * **хедз-ап** — кнопка ставит малый блайнд и ходит первой до флопа;
    * **мёртвая кнопка** — кнопка может стоять на месте, которое эту раздачу
      не играет (игрок встал, ушёл в сит-аут, ждёт большого блайнда). Тогда
      малым блайндом становится первое место круга, а не пустое кнопочное.

  Анте бывает двух видов и это разные деньги: `:per_player` платят все и
  оно считается их ставкой (все внесли поровну, поэтому уравнивание не
  ломается), `:big_blind` вносит за стол один игрок — и вот оно мёртвое.
  """

  @behaviour BlockPoker.Engine.BettingStructure

  alias BlockPoker.Engine.{EntryRules, HandSetup}

  @impl true
  def id, do: :blinds

  @impl true
  def bet_unit(%{big_blind: big_blind}), do: big_blind

  @impl true
  def entry_rules, do: EntryRules

  @impl true
  def last_to_act_preflop(%HandSetup{} = setup), do: setup |> seats() |> blind_seat(setup, :big)

  @impl true
  def forced_bets(%HandSetup{} = setup) do
    seats = seats(setup)

    antes(setup, seats) ++
      [
        %{
          seat: blind_seat(seats, setup, :small),
          kind: :small_blind,
          amount: setup.small_blind,
          live?: true
        },
        %{
          seat: blind_seat(seats, setup, :big),
          kind: :big_blind,
          amount: setup.big_blind,
          live?: true
        }
      ]
  end

  defp antes(%HandSetup{ante: 0}, _seats), do: []

  defp antes(%HandSetup{ante: ante, ante_type: :per_player}, seats) do
    Enum.map(seats, &%{seat: &1, kind: :ante, amount: ante, live?: true})
  end

  defp antes(%HandSetup{ante: ante} = setup, seats) do
    [%{seat: blind_seat(seats, setup, :big), kind: :ante, amount: ante, live?: false}]
  end

  defp seats(setup), do: setup |> HandSetup.order_from_button() |> Enum.map(& &1.seat)

  defp blind_seat([_first, _second] = seats, setup, kind) do
    small = if setup.button_seat in seats, do: setup.button_seat, else: Enum.at(seats, 0)

    case kind do
      :small -> small
      :big -> Enum.find(seats, &(&1 != small))
    end
  end

  defp blind_seat(seats, _setup, :small), do: Enum.at(seats, 0)
  defp blind_seat(seats, _setup, :big), do: Enum.at(seats, 1)
end
