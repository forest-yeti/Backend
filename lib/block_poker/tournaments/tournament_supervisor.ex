defmodule BlockPoker.Tournaments.TournamentSupervisor do
  @moduledoc """
  Динамический супервизор инстансов турниров.

  Отдельный от `TableSupervisor` намеренно, хотя оба `:one_for_one`.
  Столы и турниры падают по-разному и стоят разного: падение стола теряет
  одну раздачу, падение турнира — рассадку сотни человек. Смешав их в
  одном супервизоре, мы бы получили дерево, в котором дорогой процесс
  соседствует с дешёвым и перезапускается по тем же правилам.

  Второе: турнир **владеет** своими столами. Он поднимает их через
  `TableSupervisor` и гасит, когда схлопывает. Будь он их супервизором,
  падение турнира уносило бы столы вместе с раздачами — а восстановление
  как раз и опирается на то, что столы можно поднять заново из снапшота.
  """

  use DynamicSupervisor

  alias BlockPoker.Tournaments.TournamentServer

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_tournament(keyword()) :: DynamicSupervisor.on_start_child()
  def start_tournament(opts) do
    DynamicSupervisor.start_child(__MODULE__, {TournamentServer, opts})
  end

  @spec stop_tournament(pid()) :: :ok | {:error, :not_found}
  def stop_tournament(pid), do: DynamicSupervisor.terminate_child(__MODULE__, pid)
end
