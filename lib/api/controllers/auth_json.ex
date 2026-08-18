defmodule Api.AuthJSON do
  @moduledoc """
  Сериализация сессии. Наружу уходят только публичные поля пользователя:
  `password_hash` и `password` сюда не попадают ни при каких условиях.
  """

  alias BlockPoker.Accounts.User
  alias BlockPoker.Wallet.UserWallet

  def session(%{session: session}) do
    %{
      token: session.token,
      refresh_token: session.refresh_token,
      expires_in: session.expires_in,
      user: user(session.user),
      wallets: Enum.map(session.wallets, &wallet/1)
    }
  end

  defp user(%User{} = user) do
    %{id: user.id, name: user.name, email: user.email, avatar: user.avatar}
  end

  defp wallet(%UserWallet{} = wallet) do
    %{type: wallet.type, amount: wallet.amount}
  end
end
