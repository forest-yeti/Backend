defmodule BlockPoker.AccountsFixtures do
  @moduledoc """
  Фабрики учётных записей. Всё создаётся через публичный API контекста,
  а не прямыми `Repo.insert` (§11 CLAUDE.md).
  """

  alias BlockPoker.Accounts

  def valid_password, do: "correct horse battery"

  def unique_name, do: "player_#{System.unique_integer([:positive])}"
  def unique_email, do: "user#{System.unique_integer([:positive])}@example.com"

  def valid_user_attrs(overrides \\ %{}) do
    Map.merge(
      %{"name" => unique_name(), "email" => unique_email(), "password" => valid_password()},
      Map.new(overrides, fn {k, v} -> {to_string(k), v} end)
    )
  end

  def user_fixture(overrides \\ %{}) do
    {:ok, user} = Accounts.register(valid_user_attrs(overrides))
    user
  end
end
