defmodule BlockPoker.Engine.Ofc.Score do
  @moduledoc """
  Расчёт раздачи: попарно, каждый с каждым.

  За выигранный бокс `+1`, за проигранный `-1`, равенство — ноль. Взявший
  все три бокса получает **скуп**: `+3` сверх линий, итого `+6` с этого
  соперника. Схему 1-6 выбрали, а не 1-3-6 по числу боксов, потому что она
  де-факто стандарт онлайн-OFC и не поощряет размен двух боксов на один.

  Фол: мёртвая рука проигрывает все боксы каждому нефолнувшему — шесть очков
  плюс его роялти. Фолнувший роялти не получает, но чужие оплачивает. Оба
  фолнули — между ними ноль.

  Главный инвариант дисциплины: **сумма очков всех участников равна нулю**.
  Он держится тем, что здесь считается только попарная разность, а итог
  места — её сумма; ни одна ветка не начисляет очки в одну сторону.
  """

  alias BlockPoker.Engine.HandRank
  alias BlockPoker.Engine.Ofc.{Board, Royalties}

  @scoop_bonus 3

  @typedoc "Итог одного места: раскладка, премии, попарные разности и сумма."
  @type entry :: %{
          foul?: boolean(),
          royalties: %{rows: map(), total: non_neg_integer()},
          against: %{pos_integer() => integer()},
          total: integer()
        }

  @doc """
  Итог раздачи по раскладкам мест.

  На вход — собранные раскладки, на выход — по записи на место. Функция
  чистая и ничего не знает ни про фишки, ни про стеки: перевод очков в
  фишки живёт в `Ofc.Settlement`, потому что там начинается ограничение
  по стеку, а здесь его быть не должно.
  """
  @spec score(%{pos_integer() => Board.t()}, module() | HandRank.Context.t()) :: %{
          pos_integer() => entry()
        }
  def score(boards, context) do
    seats = boards |> Map.keys() |> Enum.sort()

    prepared =
      Map.new(boards, fn {seat, board} ->
        {seat,
         %{
           foul?: Board.foul?(board, context),
           ranks: Map.new(Board.rows(), &{&1, Board.rank(board, &1, context)}),
           royalties: Royalties.for_board(board, context)
         }}
      end)

    Map.new(seats, fn seat ->
      against =
        seats
        |> Enum.reject(&(&1 == seat))
        |> Map.new(&{&1, head_to_head(prepared[seat], prepared[&1])})

      entry = %{
        foul?: prepared[seat].foul?,
        royalties: prepared[seat].royalties,
        against: against,
        total: against |> Map.values() |> Enum.sum()
      }

      {seat, entry}
    end)
  end

  @doc """
  Очки одного места против одного соперника. Положительное — выигрыш.

  Вынесена отдельно и публична ради теста: попарная разность — то место, где
  правило скупа и правило фола либо верны, либо нет.
  """
  @spec head_to_head(map(), map()) :: integer()
  def head_to_head(%{foul?: true}, %{foul?: true}), do: 0

  def head_to_head(%{foul?: true}, %{royalties: %{total: royalties}}),
    do: -(lines_max() + royalties)

  def head_to_head(%{royalties: %{total: royalties}}, %{foul?: true}),
    do: lines_max() + royalties

  def head_to_head(mine, theirs) do
    lines =
      Enum.map(Board.rows(), fn row ->
        case HandRank.compare(mine.ranks[row], theirs.ranks[row]) do
          :gt -> 1
          :lt -> -1
          :eq -> 0
        end
      end)

    scoop =
      cond do
        Enum.all?(lines, &(&1 == 1)) -> @scoop_bonus
        Enum.all?(lines, &(&1 == -1)) -> -@scoop_bonus
        true -> 0
      end

    Enum.sum(lines) + scoop + mine.royalties.total - theirs.royalties.total
  end

  @doc """
  Сколько очков стоит проигрыш всех линий со скупом. Столько же отдаёт
  фолнувший — мёртвая рука проигрывает каждый бокс по определению.
  """
  @spec lines_max() :: pos_integer()
  def lines_max, do: length(Board.rows()) + @scoop_bonus
end
