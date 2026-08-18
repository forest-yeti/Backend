defmodule Api.RateLimiter do
  @moduledoc """
  Скользящее окно на ETS. Отдельного сервиса не заводим: ограничение нужно
  только HTTP-слою (логин, регистрация, refresh) и живёт в памяти ноды.

  GenServer здесь — владелец таблицы, а не точка синхронизации: чтение и
  запись идут напрямую из процесса запроса.
  """

  use GenServer

  @table __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Регистрирует попытку. `:ok` — можно, `{:error, :rate_limited}` — лимит выбран.
  """
  @spec hit(term(), pos_integer(), pos_integer()) :: :ok | {:error, :rate_limited}
  def hit(key, limit, window_ms) do
    now = System.system_time(:millisecond)
    drop_expired(key, now - window_ms)

    if count(key) >= limit do
      {:error, :rate_limited}
    else
      :ets.insert(@table, {key, now})
      :ok
    end
  end

  @doc "Очистка всего окна. Нужна тестам, чтобы соседние кейсы не влияли друг на друга."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:bag, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  defp drop_expired(key, cutoff) do
    :ets.select_delete(@table, [
      {{:"$1", :"$2"}, [{:==, :"$1", {:const, key}}, {:<, :"$2", cutoff}], [true]}
    ])
  end

  defp count(key), do: length(:ets.lookup(@table, key))
end
