defmodule BlockPoker.Engine.Reveal do
  @moduledoc """
  Кто на вскрытии обязан показать карты, а кто вправе их спрятать.

  За живым столом вскрытие — не «все разом перевернули». Оно идёт по кругу
  в определённом порядке, и каждый следующий игрок открывается, **только
  если бьёт всё показанное до него**. Заведомо проигравший руку не обязан
  её показывать: он говорит «мук» и отдаёт карты неоткрытыми. Это не
  косметика, а часть игры — по тому, что противник показал, а что спрятал,
  читается его диапазон.

  Порядок вскрытия:

    * первым открывается последний, кто ставил или повышал на ривере, —
      он же и заявлял сильнейшую руку торговлей;
    * если на последней улице все чекнули, первым открывается ближайший
      от кнопки по часовой стрелке, то есть тот, кто говорил первым;
    * дальше — по кругу.

  Отдельный случай — олл-ин. Когда ставить больше некому и борд доводится
  без торговли, карты вскрываются **до** прихода борда и мука нет ни у
  кого: иначе игроки увидели бы карты только победителя и не смогли бы
  проверить раздачу.

  Модуль чистый: он принимает раздачу и её результат, а решает только, чьи
  карты уходят в сокет. Никаких процессов и никакого I/O.
  """

  alias BlockPoker.Engine.Hand

  @type decision :: %{pos_integer() => :show | :muck}

  @doc """
  Порядок вскрытия: места претендентов, начиная с того, кто показывает первым.

  Порядок берётся из самой раздачи (`hand.order` — места от кнопки по
  часовой стрелке) и её последнего агрессора, поэтому не зависит от того,
  как их когда-то посадили за стол.
  """
  @spec order(Hand.t()) :: [pos_integer()]
  def order(%Hand{} = hand) do
    contenders =
      hand.order
      |> Enum.map(&Map.get(hand.players, &1))
      |> Enum.reject(&(&1 == nil or &1.status == :folded))
      |> Enum.map(& &1.seat)

    case Enum.find_index(contenders, &(&1 == hand.aggressor)) do
      # Агрессора нет (на последней улице только чекали) либо он сбросил:
      # открывается первый говоривший, то есть первый по кругу от кнопки.
      nil -> contenders
      index -> Enum.drop(contenders, index) ++ Enum.take(contenders, index)
    end
  end

  @doc """
  Кто показывает карты, а кто мучует.

  `results` — уже посчитанный итог раздачи: ранжировка по каждому прогону
  берётся из него, а не считается заново. Так решение о показе не может
  разойтись с решением о том, кто забрал банк.

  Раздача, не дошедшая до вскрытия (все сбросили), не открывает никого:
  победитель показывает карты только сам, через окно после раздачи.
  """
  @spec decide(Hand.t(), map()) :: decision()
  def decide(%Hand{} = hand, %{showdown?: false}) do
    Map.new(hand.players, fn {seat, _player} -> {seat, :muck} end)
  end

  def decide(%Hand{} = hand, %{showdown?: true} = results) do
    order = order(hand)
    mucked = Map.new(hand.players, fn {seat, _player} -> {seat, :muck} end)

    if all_in_showdown?(hand) do
      # Торговли больше не будет: прятать нечего и не от кого.
      Enum.reduce(order, mucked, &Map.put(&2, &1, :show))
    else
      places = places_by_run(results)
      winners = winners(results)

      {decision, _best} =
        Enum.reduce(order, {mucked, empty_best(places)}, fn seat, {decision, best} ->
          seat_places = Enum.map(places, &Map.get(&1, seat))

          # Забравший банк открывается всегда. Место в ранжировке для этого
          # не годится: в hi-lo вариантах слабейшая по high рука забирает
          # low-половину, и по одному месту она выглядела бы проигравшей.
          if seat in winners or beats_shown?(seat_places, best) do
            {Map.put(decision, seat, :show), update_best(best, seat_places)}
          else
            # Спрятанная рука не поднимает планку: её никто не видел.
            {decision, best}
          end
        end)

      decision
    end
  end

  # Открывается тот, кто хотя бы на одном борде не хуже всего показанного
  # до него. «Не хуже» — потому что делящий банк обязан руку показать.
  defp beats_shown?(places, best) do
    [places, best]
    |> Enum.zip()
    |> Enum.any?(fn
      {nil, _best} -> false
      {_place, nil} -> true
      {place, best} -> place <= best
    end)
  end

  defp update_best(best, places) do
    [best, places]
    |> Enum.zip()
    |> Enum.map(fn
      {best, nil} -> best
      {nil, place} -> place
      {best, place} -> min(best, place)
    end)
  end

  defp empty_best(places), do: Enum.map(places, fn _run -> nil end)

  # Кто забрал хотя бы часть хотя бы одного банка на любом прогоне.
  defp winners(results) do
    results.runs
    |> Enum.flat_map(& &1.pots)
    |> Enum.flat_map(& &1.winners)
    |> MapSet.new()
  end

  # Место в ранжировке по каждому прогону: чем меньше, тем рука сильнее.
  defp places_by_run(results) do
    Enum.map(results.runs, fn run ->
      Map.new(run.placements, &{&1.player_id, &1.place})
    end)
  end

  # Доводка борта без торговли: кто-то пошёл олл-ин и ответы уже собраны.
  defp all_in_showdown?(%Hand{runout?: true}), do: true

  defp all_in_showdown?(%Hand{} = hand) do
    hand
    |> Map.fetch!(:players)
    |> Map.values()
    |> Enum.filter(&(&1.status != :folded))
    |> Enum.count(&(&1.status == :active))
    |> Kernel.<=(1)
  end
end
