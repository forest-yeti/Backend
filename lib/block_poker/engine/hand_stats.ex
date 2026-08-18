defmodule BlockPoker.Engine.HandStats do
  @moduledoc """
  Счётчик показателей одной раздачи: складывается из тех же событий, что
  уходят клиенту, и на выходе даёт прибавку к `Engine.Stats` по каждому месту.

  Источник — события, а не отдельный проход по состоянию: список фактов у
  раздачи уже есть, и он один и тот же для broadcast'а, истории и статистики
  (§7 CLAUDE.md). Второй способ узнать, что игрок коллировал, означал бы
  второе определение колла.

  Тонкость, ради которой модуль вообще существует отдельно: **олл-ин не
  всегда агрессия**. Игрок с коротким стеком, вложивший всё и не перебивший
  текущую ставку, сделал колл, а не рейз, — событие в обоих случаях помечено
  `all_in`. Поэтому здесь ведётся собственная ставка улицы и агрессией
  считается только `to > bet`.
  """

  alias BlockPoker.Engine.{Hand, Stats}

  @type t :: %__MODULE__{
          street: Hand.street(),
          bet: non_neg_integer(),
          preflop_raises: non_neg_integer(),
          players: %{pos_integer() => map()}
        }

  defstruct street: :preflop, bet: 0, preflop_raises: 0, players: %{}

  @player %{
    voluntary?: false,
    raised_preflop?: false,
    three_bet_chance?: false,
    three_bet?: false,
    folded?: false,
    saw_flop?: false,
    aggressive: 0,
    calls: 0
  }

  @doc "Начало раздачи: места уже получили карты, ставка равна блайнду."
  @spec new(Hand.t()) :: t()
  def new(%Hand{} = hand) do
    %__MODULE__{
      street: hand.street,
      bet: hand.bet,
      players: Map.new(hand.players, fn {seat, _player} -> {seat, @player} end)
    }
  end

  @doc "Учесть одно событие раздачи. Незнакомое событие ничего не меняет."
  @spec track(t() | nil, tuple()) :: t() | nil
  def track(nil, _event), do: nil

  def track(%__MODULE__{} = stats, {:action_taken, payload}) do
    case Map.get(stats.players, payload.seat) do
      nil -> stats
      player -> apply_action(stats, payload, player)
    end
  end

  def track(%__MODULE__{} = stats, {:street_dealt, %{street: street}}) do
    stats = %{stats | street: street, bet: 0}
    if street == :flop, do: mark_saw_flop(stats), else: stats
  end

  def track(%__MODULE__{} = stats, _event), do: stats

  @doc """
  Прибавка к показателям сессии по каждому месту.

  Вскрытие берётся из завершённой раздачи, а не из событий: дошёл ли игрок
  до вскрытия — это её итог, и он уже посчитан в `results`.
  """
  @spec finish(t() | nil, Hand.t()) :: %{pos_integer() => Stats.t()}
  def finish(nil, _hand), do: %{}

  def finish(%__MODULE__{} = stats, %Hand{} = hand) do
    Map.new(stats.players, fn {seat, player} ->
      {seat,
       %Stats{
         hands: 1,
         vpip: flag(player.voluntary?),
         pfr: flag(player.raised_preflop?),
         three_bet_chances: flag(player.three_bet_chance?),
         three_bets: flag(player.three_bet?),
         saw_flop: flag(player.saw_flop?),
         showdowns: flag(showdown?(hand, seat)),
         aggressive: player.aggressive,
         calls: player.calls
       }}
    end)
  end

  # --- действия -------------------------------------------------------------

  defp apply_action(stats, %{action: "fold"} = payload, player) do
    stats
    |> note_three_bet_chance(payload.seat, player)
    |> update_player(payload.seat, &%{&1 | folded?: true})
  end

  defp apply_action(stats, %{action: "check"}, _player), do: stats

  defp apply_action(stats, %{action: "call"} = payload, player) do
    stats
    |> note_three_bet_chance(payload.seat, player)
    |> count_call(payload.seat, Map.get(payload, :amount, 0))
  end

  defp apply_action(stats, %{action: action} = payload, player)
       when action in ["raise", "all_in"] do
    to = Map.get(payload, :to, 0)

    if to > stats.bet do
      stats
      |> note_three_bet_chance(payload.seat, player)
      |> count_raise(payload.seat, to)
    else
      # Олл-ин, не перебивший ставку, — это колл на остаток стека.
      stats
      |> note_three_bet_chance(payload.seat, player)
      |> count_call(payload.seat, Map.get(payload, :amount, 0))
    end
  end

  defp apply_action(stats, _payload, _player), do: stats

  defp count_call(stats, seat, amount) do
    update_player(stats, seat, fn player ->
      cond do
        amount <= 0 -> player
        stats.street == :preflop -> %{player | voluntary?: true}
        true -> %{player | calls: player.calls + 1}
      end
    end)
  end

  defp count_raise(stats, seat, to) do
    three_bet? = stats.street == :preflop and stats.preflop_raises > 0

    stats =
      update_player(stats, seat, fn player ->
        if stats.street == :preflop do
          %{
            player
            | voluntary?: true,
              raised_preflop?: true,
              three_bet?: player.three_bet? or three_bet?
          }
        else
          %{player | aggressive: player.aggressive + 1}
        end
      end)

    raises = if stats.street == :preflop, do: stats.preflop_raises + 1, else: stats.preflop_raises
    %{stats | bet: to, preflop_raises: raises}
  end

  # Возможность ререйза — это момент, когда до хода игрока на префлопе уже
  # был рейз. Считается один раз за раздачу и независимо от того, что игрок
  # в итоге сделал: пас в такой ситуации — тоже использованная возможность.
  defp note_three_bet_chance(stats, seat, player) do
    if stats.street == :preflop and stats.preflop_raises > 0 and not player.three_bet_chance? do
      put_player(stats, seat, %{player | three_bet_chance?: true})
    else
      stats
    end
  end

  defp mark_saw_flop(stats) do
    players =
      Map.new(stats.players, fn {seat, player} ->
        {seat, %{player | saw_flop?: player.saw_flop? or not player.folded?}}
      end)

    %{stats | players: players}
  end

  defp showdown?(%Hand{results: nil}, _seat), do: false

  defp showdown?(%Hand{results: results} = hand, seat) do
    case Map.get(hand.players, seat) do
      nil -> false
      player -> results.showdown? and player.status != :folded
    end
  end

  defp put_player(stats, seat, player),
    do: %{stats | players: Map.put(stats.players, seat, player)}

  defp update_player(stats, seat, fun) do
    case Map.get(stats.players, seat) do
      nil -> stats
      player -> put_player(stats, seat, fun.(player))
    end
  end

  defp flag(true), do: 1
  defp flag(false), do: 0
end
