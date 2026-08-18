defmodule BlockPoker.Tables.TableRegistry do
  @moduledoc """
  Адресация комнат. Единственное место, которое придётся менять при переходе
  на кластер (§8 CLAUDE.md), — поэтому кортеж `:via` собирается здесь, а не
  разбросан по вызовам.
  """

  @spec child_spec_options() :: keyword()
  def child_spec_options, do: [keys: :unique, name: __MODULE__]

  @spec via(Ecto.UUID.t()) :: {:via, Registry, {module(), {:table, Ecto.UUID.t()}}}
  def via(room_id), do: {:via, Registry, {__MODULE__, {:table, room_id}}}

  @spec whereis(Ecto.UUID.t()) :: pid() | nil
  def whereis(room_id) do
    case Registry.lookup(__MODULE__, {:table, room_id}) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end
end
