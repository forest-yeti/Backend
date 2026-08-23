defmodule BlockPoker.Engine.Elimination do
  @moduledoc """
  Места вылетевших: кто какое занял, когда выбыли несколько сразу.

  Чистый расчёт. Правило простое — **место = число выживших + 1 на момент
  вылета**, — и вся сложность в одной раздаче, которая выбивает двоих
  и больше.

  ## Тайбрейк

  Одновременный вылет разводится по стеку **на начало раздачи**: у кого
  стек был больше, тот занимает более высокое место. Это стандарт, и он
  единственный, который не зависит от порядка разрешения банков: стеки
  до раздачи уже зафиксированы, а «кто раньше кончился» внутри одной
  раздачи смысла не имеет — они кончились одновременно.

  При **равных** стеках место не достаётся ни тому, ни другому: они
  делят сумму своих мест поровну. Отдать более высокое место по номеру
  сиденья значило бы решить деньгами то, что игра не решила.

  Остаток от деления при равных стеках уходит игроку, ближайшему к
  кнопке по часовой стрелке, — тот же тайбрейк, что у нечётных фишек
  банка и у нечётных единиц головы.
  """

  @typedoc """
  Выбывший. `stack_before` — стек на начало раздачи, `seat` нужен только
  для тайбрейка при равных стеках.
  """
  @type victim :: %{entry_id: term(), seat: pos_integer(), stack_before: non_neg_integer()}

  @typedoc """
  Присвоенное место. `shared_places` — все места, чьи призы складываются
  и делятся между `tied_with` поровну; у одиночного вылета это `[place]`,
  и делить нечего.
  """
  @type placement :: %{
          entry_id: term(),
          place: pos_integer(),
          shared_places: [pos_integer()],
          tied_with: [term()]
        }

  @typedoc "Расположение стола — нужно только для остатка при равных стеках."
  @type table :: %{button_seat: pos_integer(), table_size: pos_integer()}

  @doc """
  Распределяет места между выбывшими одной раздачей.

  `survivors` — сколько игроков осталось **после** раздачи. Места
  раздаются с `survivors + 1` вверх: последний выбывший из двадцати
  занимает двадцатое, а не первое свободное сверху.
  """
  @spec assign([victim()], non_neg_integer(), table()) :: [placement()]
  def assign([], _survivors, _table), do: []

  def assign(victims, survivors, table) do
    victims
    |> Enum.sort_by(
      &{-&1.stack_before, Integer.mod(&1.seat - table.button_seat, table.table_size)}
    )
    |> Enum.chunk_by(& &1.stack_before)
    |> number_groups(survivors + 1)
    |> Enum.flat_map(&expand_group/1)
  end

  @doc """
  Делит сумму призов связанных мест между игроками поровну.

  Остаток — первому по тайбрейку, то есть ближайшему к кнопке.
  Существует отдельной функцией, потому что суммы приходят из
  `Engine.TournamentPayout`, а деление — правило вылета, а не выплаты.
  """
  @spec split_prize(non_neg_integer(), pos_integer()) :: [non_neg_integer()]
  def split_prize(total, count) when count > 0 do
    base = div(total, count)
    odd = total - base * count

    Enum.map(0..(count - 1), fn index -> base + if(index < odd, do: 1, else: 0) end)
  end

  # Группа — это игроки с одинаковым стеком: им достаётся набор подряд
  # идущих мест, и внутри группы места не различаются.
  defp number_groups(groups, first_place) do
    {numbered, _next} =
      Enum.map_reduce(groups, first_place, fn group, place ->
        places = Enum.to_list(place..(place + length(group) - 1))
        {{group, places}, place + length(group)}
      end)

    numbered
  end

  defp expand_group({[victim], [place]}) do
    [%{entry_id: victim.entry_id, place: place, shared_places: [place], tied_with: []}]
  end

  defp expand_group({group, places}) do
    ids = Enum.map(group, & &1.entry_id)

    Enum.zip_with(group, places, fn victim, place ->
      %{
        entry_id: victim.entry_id,
        place: place,
        shared_places: places,
        tied_with: ids -- [victim.entry_id]
      }
    end)
  end
end
