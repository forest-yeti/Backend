defmodule BlockPoker.ClientRelease do
  @moduledoc """
  Версия клиентского приложения: что считать актуальным и что — устаревшим.

  Живёт в ядре, а не в транспорте, по §3: «устарел ли клиент» — это решение,
  а не разбор payload'а. `UserSocket` и `Api.ClientController` только зовут
  `check/1` и `info/0` и рендерят результат.

  Версия клиента (`client_vsn`, semver вида `1.4.2`) — это версия сборки
  Electron. Она намеренно отделена от `Socket.Protocol.Version`: та описывает
  формат сообщений и меняется редко, эта — растёт на каждом релизе.

  Обе границы читаются из конфигурации, то есть поднимаются переменной
  окружения без передеплоя кода:

    * `minimum` — ниже неё соединение не даётся вовсе (`:client_too_old`);
    * `current` — актуальная сборка; клиент между `minimum` и `current`
      играет, но знает, что есть новее.
  """

  @type info :: %{
          current: String.t(),
          minimum: String.t(),
          feed_url: String.t() | nil
        }

  @doc """
  Что клиенту нужно знать об обновлениях: обе границы версий и адрес фида,
  с которого `electron-updater` качает сборку.
  """
  @spec info() :: info()
  def info do
    %{
      current: current(),
      minimum: minimum(),
      feed_url: feed_url()
    }
  end

  @spec current() :: String.t()
  def current, do: config(:current, "0.0.0")

  @spec minimum() :: String.t()
  def minimum, do: config(:minimum, "0.0.0")

  @doc """
  Адрес фида обновлений. Отдаётся клиенту, а не зашивается в сборку: иначе
  переезд раздачи на другой хост потребовал бы релиза того самого клиента,
  который этим релизом и обновляют.
  """
  @spec feed_url() :: String.t() | nil
  def feed_url, do: config(:feed_url, nil)

  @doc """
  Пускаем ли эту сборку в игру.

  Версия не передана — считаем нулевой: клиент, который про версии не знает,
  собран до появления этой проверки, и он ровно тот, кого `minimum` отсекает.
  Нераспознанная строка трактуется так же — иначе гейт обходился бы мусором.
  """
  @spec check(String.t() | nil) :: :ok | {:error, :client_too_old}
  def check(client_vsn) do
    if below?(client_vsn, minimum()), do: {:error, :client_too_old}, else: :ok
  end

  @doc "Есть ли сборка новее той, что у клиента."
  @spec outdated?(String.t() | nil) :: boolean()
  def outdated?(client_vsn), do: below?(client_vsn, current())

  defp below?(client_vsn, boundary) do
    case {parse(client_vsn), parse(boundary)} do
      # Граница не настроена или задана мусором — не отсекаем никого:
      # ошибка конфигурации не должна выглядеть как массовый бан клиентов.
      {_client, :error} -> false
      {:error, _boundary} -> true
      {{:ok, client}, {:ok, limit}} -> Version.compare(client, limit) == :lt
    end
  end

  defp parse(nil), do: {:ok, Version.parse!("0.0.0")}
  defp parse(vsn) when is_binary(vsn), do: Version.parse(vsn)
  defp parse(_vsn), do: :error

  defp config(key, default) do
    :block_poker
    |> Application.get_env(:client_release, [])
    |> Keyword.get(key, default)
  end
end
