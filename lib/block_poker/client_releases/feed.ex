defmodule BlockPoker.ClientReleases.Feed do
  @moduledoc """
  Актуальная и минимальная версии клиента — то, что спрашивают на каждом
  подключении сокета.

  Значения держатся в `:persistent_term`, а не читаются из БД: `check/1`
  зовётся при каждом handshake, и ходить за этим в MySQL — лишний запрос
  на каждого входящего игрока. Кэш обновляется явно, в момент публикации
  или удаления релиза, а не по таймеру: устаревать ему неоткуда, потому
  что менять эти значения умеет только панель.

  Пока кэш не заполнен, границы берутся из конфигурации. Это не
  «пустое состояние», а рабочее: нода без единого загруженного релиза
  живёт на значениях из окружения ровно так же, как жила до появления
  загрузки через панель.
  """

  import Ecto.Query

  alias BlockPoker.ClientReleases.Release
  alias BlockPoker.Repo

  @key {__MODULE__, :state}

  @type state :: %{current: String.t(), minimum: String.t()}

  @doc "Границы версий: из кэша, а при пустом кэше — из конфигурации."
  @spec state() :: state()
  def state, do: :persistent_term.get(@key, from_config())

  @doc """
  Пересчитывает границы по опубликованным релизам.

  Актуальная версия — **последняя опубликованная**, а не наибольшая:
  публикация старой сборки поверх новой это откат, и он обязан работать.
  """
  @spec refresh() :: state()
  def refresh do
    published = Repo.all(from r in Release, where: not is_nil(r.published_at))

    state =
      case latest(published) do
        nil -> from_config()
        current -> %{current: current.version, minimum: minimum(published, current.version)}
      end

    :persistent_term.put(@key, state)
    state
  end

  @doc "Сбрасывает кэш к конфигурации. Нужен тестам и откату раздачи."
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@key)
    :ok
  end

  defp latest([]), do: nil
  defp latest(releases), do: Enum.max_by(releases, & &1.published_at, DateTime)

  # Минимум поднимают релизы с флагом «обязательное», но **не выше
  # актуального**. Без этого ограничения откат на предыдущую сборку после
  # обязательного обновления запер бы всех: минимум остался бы от версии,
  # которой в фиде уже нет, и обновиться до него было бы нечем.
  defp minimum(published, current_version) do
    published
    |> Enum.filter(& &1.mandatory)
    |> Enum.map(& &1.version)
    |> Enum.filter(&(compare(&1, current_version) != :gt))
    # Ни одного обязательного релиза — минимума нет вовсе. Значение из
    # конфигурации сюда не подставляется: как только релизы поехали через
    # панель, окружение перестаёт быть источником истины для границ.
    |> Enum.max_by(&Version.parse!/1, Version, fn -> "0.0.0" end)
  end

  defp compare(left, right), do: Version.compare(left, right)

  defp from_config do
    config = Application.get_env(:block_poker, :client_release, [])

    %{
      current: Keyword.get(config, :current, "0.0.0"),
      minimum: Keyword.get(config, :minimum, "0.0.0")
    }
  end
end
