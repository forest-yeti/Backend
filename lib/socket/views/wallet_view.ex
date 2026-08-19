defmodule Socket.Views.WalletView do
  @moduledoc """
  Кошельки игрока на пути в сокет.

  Наружу уходят тип и сумма — ровно то, что рисует клиент. Идентификатор
  кошелька не отдаётся: клиенту он не нужен ни для чего, а по нему
  адресуются деньги.

  Событие о движении денег своего рендера не требует: контекст присылает
  его уже готовым набором фактов (§7 CLAUDE.md), и вью нечего к нему
  добавить — схема журнала в транспорт не приходит и не должна.
  """

  alias BlockPoker.Wallet.UserWallet

  @doc "Снапшот всех кошельков — отдаётся при join."
  @spec render([UserWallet.t()]) :: map()
  def render(wallets), do: %{wallets: Enum.map(wallets, &wallet/1)}

  defp wallet(%UserWallet{} = wallet), do: %{type: wallet.type, amount: wallet.amount}
end
