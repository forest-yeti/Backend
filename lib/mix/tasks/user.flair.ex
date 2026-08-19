defmodule Mix.Tasks.User.Flair do
  @shortdoc "Показывает или назначает косметику пользователя"

  @moduledoc """
  Косметика — то, чем стол выделяет игрока: цвет ника и прочее оформление.
  Выдаётся стримерам, партнёрам и прочим, кого нужно отличить от остальных.

      mix user.flair player@example.com              # показать текущую
      mix user.flair player@example.com influencer   # выделить
      mix user.flair Player default                  # вернуть обычный вид

  Пользователь ищется по email или нику.

  Прав косметика не даёт никаких и на правила игры не влияет: это ровно и
  только внешний вид. Ставится она **только отсюда** — через сокет игрок
  себе метку не поставит, иначе выделение перестало бы что-либо значить.
  С ролью (`mix user.role`) не связана: роль наружу не уходит вовсе, а
  косметика затем и существует, чтобы её видели.
  """

  use Mix.Task

  alias BlockPoker.Accounts
  alias BlockPoker.Accounts.User

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv) do
    case argv do
      [identifier] -> show(identifier)
      [identifier, flair] -> assign(identifier, flair)
      _other -> Mix.raise("использование: mix user.flair <email|ник> [#{flairs()}]")
    end
  end

  defp show(identifier) do
    identifier |> fetch!() |> report()
  end

  defp assign(identifier, flair) do
    unless flair in User.flairs() do
      Mix.raise("неизвестная косметика #{inspect(flair)}; допустимы: #{flairs()}")
    end

    user = fetch!(identifier)

    case Accounts.set_flair(user, flair) do
      {:ok, updated} -> report(updated)
      {:error, changeset} -> Mix.raise("косметика не назначена: #{inspect(changeset.errors)}")
    end
  end

  defp report(user) do
    Mix.shell().info("#{user.name} <#{user.email}> — косметика: #{user.flair}")
  end

  defp fetch!(identifier) do
    case Accounts.find_user(identifier) do
      {:ok, user} -> user
      {:error, :not_found} -> Mix.raise("пользователь #{inspect(identifier)} не найден")
    end
  end

  defp flairs, do: Enum.join(User.flairs(), " | ")
end
