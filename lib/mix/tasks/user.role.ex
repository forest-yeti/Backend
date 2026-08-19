defmodule Mix.Tasks.User.Role do
  @shortdoc "Показывает или назначает роль пользователя"

  @moduledoc """
  Роль — служебное поле сервера: клиенту она не отдаётся и через сокет не
  меняется. Единственный способ выдать её — эта команда.

      mix user.role player@example.com          # показать текущую роль
      mix user.role player@example.com admin    # сделать администратором
      mix user.role Player default              # вернуть обычным игроком

  Пользователь ищется по email или нику. Роль администратора даёт ровно одно
  право: запускать вручную стол, у которого `auto_start: false`.
  """

  use Mix.Task

  alias BlockPoker.Accounts
  alias BlockPoker.Accounts.User

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv) do
    case argv do
      [identifier] -> show(identifier)
      [identifier, role] -> assign(identifier, role)
      _other -> Mix.raise("использование: mix user.role <email|ник> [#{roles()}]")
    end
  end

  defp show(identifier) do
    user = fetch!(identifier)
    Mix.shell().info("#{user.name} <#{user.email}> — роль: #{user.role}")
  end

  defp assign(identifier, role) do
    unless role in Enum.map(User.roles(), &to_string/1) do
      Mix.raise("неизвестная роль #{inspect(role)}; допустимы: #{roles()}")
    end

    user = fetch!(identifier)

    case Accounts.set_role(user, role) do
      {:ok, updated} ->
        Mix.shell().info("#{updated.name} <#{updated.email}> — роль: #{updated.role}")

      {:error, changeset} ->
        Mix.raise("роль не назначена: #{inspect(changeset.errors)}")
    end
  end

  defp fetch!(identifier) do
    case Accounts.find_user(identifier) do
      {:ok, user} -> user
      {:error, :not_found} -> Mix.raise("пользователь #{inspect(identifier)} не найден")
    end
  end

  defp roles, do: User.roles() |> Enum.map_join(" | ", &to_string/1)
end
