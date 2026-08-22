defmodule BlockPoker.Engine.Ofc.Settlement do
  @moduledoc """
  Перевод очков в фишки: попарные переносы между стеками.

  Очко стоит `point_value` фишек. Банка в дисциплине нет, поэтому расчёт —
  это не дележ пота, а прямые переносы должник → кредитор.

  Стека может не хватить. Правило то же по духу, что у сайд-потов: **нельзя
  проиграть больше, чем есть на столе**. Потолок берётся по стеку должника
  на момент расчёта, до любых переносов, — так итог не зависит от порядка
  их применения и ни один стек не уходит в минус.

  Кредиторов у должника может быть несколько, и денег на всех не хватает.
  Делим **пропорционально долгу**: обыгравший на тридцать очков получает
  больше обыгравшего на двадцать. Остаток целочисленного деления раздаётся
  по возрастанию номера места — это единственное место, где номер вообще
  участвует, и нужен он только ради детерминированности.

  Суммарное число фишек не меняется: каждая списанная фишка ровно один раз
  начисляется. Это и проверяется property-тестом.
  """

  @typedoc "Перенос фишек: сколько и от кого кому."
  @type transfer :: %{from: pos_integer(), to: pos_integer(), amount: pos_integer()}

  @doc """
  Переносы и итоговые изменения стеков.

  `scores` — попарные очки из `Ofc.Score.score/2`, `stacks` — фишки мест на
  момент расчёта.
  """
  @spec settle(%{pos_integer() => map()}, %{pos_integer() => non_neg_integer()}, pos_integer()) ::
          %{transfers: [transfer()], deltas: %{pos_integer() => integer()}}
  def settle(scores, stacks, point_value) do
    transfers =
      scores
      |> debts(point_value)
      |> Enum.sort_by(fn {debtor, _owed} -> debtor end)
      |> Enum.flat_map(fn {debtor, owed} -> pay(debtor, owed, Map.fetch!(stacks, debtor)) end)

    deltas =
      Enum.reduce(transfers, Map.new(Map.keys(stacks), &{&1, 0}), fn transfer, acc ->
        acc
        |> Map.update!(transfer.from, &(&1 - transfer.amount))
        |> Map.update!(transfer.to, &(&1 + transfer.amount))
      end)

    %{transfers: transfers, deltas: deltas}
  end

  # Кто кому сколько должен в фишках. Долг считается одной суммой: линии и
  # роялти по приоритету не разделяются — проигравший должен ровно столько,
  # сколько насчитал попарный расчёт.
  defp debts(scores, point_value) do
    for {seat, entry} <- scores,
        {opponent, points} <- entry.against,
        points < 0,
        reduce: %{} do
      acc ->
        Map.update(
          acc,
          seat,
          %{opponent => -points * point_value},
          &Map.put(&1, opponent, -points * point_value)
        )
    end
  end

  defp pay(debtor, owed, stack) do
    total = owed |> Map.values() |> Enum.sum()

    owed
    |> share(total, stack)
    |> Enum.sort_by(fn {creditor, _amount} -> creditor end)
    |> Enum.reject(fn {_creditor, amount} -> amount == 0 end)
    |> Enum.map(fn {creditor, amount} -> %{from: debtor, to: creditor, amount: amount} end)
  end

  # Стека хватает — платим полностью и ничего не делим.
  defp share(owed, total, stack) when total <= stack, do: owed

  defp share(owed, total, stack) do
    parts =
      owed
      |> Enum.sort_by(fn {creditor, _amount} -> creditor end)
      |> Enum.map(fn {creditor, amount} -> {creditor, div(amount * stack, total)} end)

    distribute(parts, stack - Enum.sum(Enum.map(parts, &elem(&1, 1))))
  end

  # Остаток целочисленного деления: по одной фишке местам в порядке номера,
  # пока остаток не кончится. Порядок нужен только ради воспроизводимости —
  # величина остатка всегда меньше числа кредиторов.
  defp distribute(parts, left) do
    parts
    |> Enum.map_reduce(left, fn
      {creditor, amount}, rest when rest > 0 -> {{creditor, amount + 1}, rest - 1}
      {creditor, amount}, rest -> {{creditor, amount}, rest}
    end)
    |> elem(0)
    |> Map.new()
  end
end
