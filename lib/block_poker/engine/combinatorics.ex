defmodule BlockPoker.Engine.Combinatorics do
  @moduledoc """
  Перебор сочетаний. Вынесен отдельно, потому что нужен и оценке руки
  (`C(7,5)` кандидатов), и точному расчёту эквити (раскладки борда).

  `reduce_combinations/4` не строит список всех сочетаний: точный префлоп —
  это `C(48,5)` ≈ 1.7 млн раскладов, материализовать их в памяти нельзя.
  """

  @spec combinations([term()], non_neg_integer()) :: [[term()]]
  def combinations(_list, 0), do: [[]]
  def combinations([], _k), do: []

  def combinations([head | tail], k) do
    Enum.map(combinations(tail, k - 1), &[head | &1]) ++ combinations(tail, k)
  end

  @doc "Число сочетаний `C(n, k)`."
  @spec count(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def count(_n, 0), do: 1
  def count(n, k) when k > n, do: 0

  def count(n, k) do
    k = min(k, n - k)
    Enum.reduce(1..k//1, 1, fn i, acc -> div(acc * (n - k + i), i) end)
  end

  @doc """
  Свёртка по сочетаниям без материализации списка. Каждое сочетание
  приходит в аккумулирующую функцию как список из `k` элементов.
  """
  @spec reduce_combinations([term()], non_neg_integer(), acc, ([term()], acc -> acc)) :: acc
        when acc: term()
  def reduce_combinations(list, k, acc, fun) do
    do_reduce(list, k, length(list), [], acc, fun)
  end

  defp do_reduce(_list, 0, _len, chosen, acc, fun), do: fun.(chosen, acc)
  defp do_reduce(_list, k, len, _chosen, acc, _fun) when k > len, do: acc

  defp do_reduce([head | tail], k, len, chosen, acc, fun) do
    acc = do_reduce(tail, k - 1, len - 1, [head | chosen], acc, fun)
    do_reduce(tail, k, len - 1, chosen, acc, fun)
  end
end
