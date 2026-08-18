defmodule BlockPoker.Tables.TableSupervisor do
  @moduledoc """
  Динамический супервизор комнат. `:one_for_one`: падение одной комнаты
  не задевает остальные (§8 CLAUDE.md).
  """

  use DynamicSupervisor

  alias BlockPoker.Tables.TableServer

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_room(keyword()) :: DynamicSupervisor.on_start_child()
  def start_room(opts) do
    DynamicSupervisor.start_child(__MODULE__, {TableServer, opts})
  end

  @spec stop_room(pid()) :: :ok | {:error, :not_found}
  def stop_room(pid), do: DynamicSupervisor.terminate_child(__MODULE__, pid)
end
