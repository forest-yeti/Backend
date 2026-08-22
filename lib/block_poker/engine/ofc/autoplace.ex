defmodule BlockPoker.Engine.Ofc.Autoplace do
  @moduledoc """
  Автоматическая раскладка сдачи: чем стол ходит за отвалившегося.

  Фолдом просроченный ход в китайском покере решить нельзя — фол здесь
  означает мёртвую руку и минус шесть очков каждому сопернику сразу. Испортить
  раздачу остальным из-за чужого разрыва связи стол не вправе, поэтому карты
  выкладываются автоматически по правилу, которое **не убивает руку, если её
  можно не убить**.

  Правило: перебрать размещения текущей сдачи, отбросить ведущие к заведомо
  мёртвой руке, из оставшихся взять максимум по роялти. Оно чистое, живёт
  здесь целиком и используется и таймером хода, и `default_action` при
  разрыве связи.

  Перебор ветвится по размеру хода, и это не ветвление по правилам игры:
  обычный ход — это две-пять карт, и его пространство обходится целиком;
  ход фантазии — тринадцать, и полный перебор там астрономический. Для него
  раскладка строится **сверху вниз по силе**: сначала лучшая пятёрка вниз,
  затем лучшая из оставшихся в середину, остаток наверх. Такая раскладка не
  фолит по построению — каждый следующий бокс выбирается из того, что уже
  оказалось слабее.
  """

  alias BlockPoker.Engine.{Card, Combinatorics, HandRank}
  alias BlockPoker.Engine.Ofc.{Board, Royalties}

  # Заведомо мёртвая ветка проигрывает любой живой, какие бы роялти она ни
  # обещала: шесть очков каждому сопернику дороже любой премии таблицы.
  @dead_penalty -1_000_000

  # Настоящая премия дороже любой ориентации карт: множитель выводит её на
  # шкалу, где она перевешивает `safety/1` целиком.
  @royalty_weight 1000

  # Перевёрнутая пара боксов дороже любой разницы в рангах: порядок боксов —
  # это правило, а сумма рангов лишь подсказка.
  @inversion_penalty 10_000

  # Совпадение рангов весит больше суммы рангов: пара сильнее старшей карты
  # независимо от того, насколько та старше.
  @shape_weight 100

  @type placement :: {Card.t(), Board.row()}

  @doc """
  Размещения и сброс для текущей сдачи.

  `discard` — сколько карт сдача требует сбросить: ноль на первой сдаче,
  одну в круге и одну в фантазии.
  """
  @spec choose(Board.t(), [Card.t()], non_neg_integer(), module() | HandRank.Context.t()) ::
          {[placement()], Card.t() | nil}
  def choose(%Board{} = board, cards, discard, context) do
    if length(cards) - discard > 5 do
      by_strength(board, cards, discard, context)
    else
      by_search(board, cards, discard, context)
    end
  end

  # --- обычный ход: полный перебор -----------------------------------------

  defp by_search(board, cards, discard, context) do
    cards
    |> splits(discard)
    |> Enum.flat_map(fn {kept, dropped} ->
      Enum.map(assignments(board, kept), &{&1, dropped})
    end)
    |> Enum.max_by(fn {placements, _dropped} -> value(board, placements, context) end)
  end

  # Какие карты остаются в игре и какая уходит в сброс.
  defp splits(cards, 0), do: [{cards, nil}]

  defp splits(cards, 1) do
    Enum.map(cards, fn dropped -> {cards -- [dropped], dropped} end)
  end

  # Все способы разложить карты по боксам с учётом их вместимости. Порядок
  # карт внутри бокса на силу руки не влияет, поэтому перебираются именно
  # назначения, а не перестановки.
  defp assignments(board, cards) do
    free = Map.new(Board.rows(), &{&1, Board.free(board, &1)})

    Enum.reduce(cards, [{[], free}], fn card, acc ->
      for {placements, left} <- acc,
          row <- Board.rows(),
          left[row] > 0 do
        {placements ++ [{card, row}], Map.update!(left, row, &(&1 - 1))}
      end
    end)
    |> Enum.map(fn {placements, _left} -> placements end)
  end

  # Ценность ветки. Заведомо мёртвая проигрывает любой живой, а дальше
  # решает, собрана ли рука.
  #
  # Премии недособранной руки **не считаются**, и это не упрощение: пока
  # рука не собрана, они не заработаны. Пара тузов наверху обещает девять
  # очков и почти гарантирует фол — жадность по обещанным премиям ровно в
  # эту ловушку и попадает. Пока карт не хватает, ветка оценивается
  # безопасностью: старшие карты должны лежать ниже, потому что рука обязана
  # усиливаться сверху вниз. На последнем размещении рука становится
  # собранной, и премии из обещанных превращаются в настоящие.
  defp value(board, placements, context) do
    {:ok, next} = Board.place(board, placements)

    cond do
      Board.dead?(next, context) -> @dead_penalty
      Board.complete?(next) -> @royalty_weight * royalties(next, context) + safety(next)
      true -> safety(next)
    end
  end

  defp royalties(board, context) do
    Enum.sum(Enum.map(Board.rows(), &Royalties.for_row(&1, Board.rank(board, &1, context))))
  end

  # Насколько раскладка «правильно ориентирована»: рука обязана усиливаться
  # сверху вниз, и у недособранной это уже видно по тому, что в боксах лежит.
  #
  # Считать здесь настоящую роспись нельзя — боксы заполнены по-разному, и
  # `HandRank` неполные карты не оценивает. Поэтому берётся грубая, но
  # достаточная мера: совпадения рангов (пара весит больше старшей карты)
  # плюс сумма рангов. Перевёрнутая пара боксов штрафуется — именно так
  # ловится «короли в середине при дамах внизу», на которых жадность по
  # сумме рангов не реагирует вовсе.
  defp safety(board) do
    potential = Map.new(Board.rows(), &{&1, potential(Board.cards(board, &1))})

    inversions =
      [{:middle, :top}, {:bottom, :middle}, {:bottom, :top}]
      |> Enum.count(fn {lower, upper} -> potential[lower] < potential[upper] end)

    -@inversion_penalty * inversions + potential[:bottom] + potential[:middle]
  end

  # Грубая сила набора карт: сначала совпадения рангов, потом сами ранги.
  defp potential(cards) do
    counts = cards |> Enum.map(&Card.rank/1) |> Enum.frequencies()

    shape =
      counts
      |> Map.values()
      |> Enum.map(&((&1 - 1) * (&1 - 1)))
      |> Enum.sum()

    shape * @shape_weight + Enum.sum(Enum.map(cards, &Card.rank/1))
  end

  # --- ход фантазии: раскладка сверху вниз по силе --------------------------

  defp by_strength(board, cards, discard, context) do
    cards
    |> splits_for_fantasy(discard)
    |> Enum.map(fn {kept, dropped} -> {arrange(board, kept, context), dropped} end)
    |> Enum.max_by(fn {placements, _dropped} -> value(board, placements, context) end)
  end

  defp splits_for_fantasy(cards, 0), do: [{cards, nil}]

  defp splits_for_fantasy(cards, 1),
    do: Enum.map(cards, fn dropped -> {cards -- [dropped], dropped} end)

  # Сначала лучшая пятёрка в нижний бокс, потом лучшая из оставшихся в
  # средний, остаток — наверх. Каждый следующий бокс выбирается из того, что
  # уже оказалось слабее, поэтому порядок «снизу вверх» соблюдён построением.
  defp arrange(_board, cards, context) do
    {bottom, rest} = best_five(cards, context)
    {middle, top} = best_five(rest, context)

    Enum.map(bottom, &{&1, :bottom}) ++
      Enum.map(middle, &{&1, :middle}) ++ Enum.map(top, &{&1, :top})
  end

  defp best_five(cards, context) do
    best =
      cards
      |> Combinatorics.combinations(5)
      |> Enum.max_by(&HandRank.best_of_five(&1, context).score)

    {best, cards -- best}
  end
end
