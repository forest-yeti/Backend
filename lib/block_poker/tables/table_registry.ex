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

  @doc """
  Все живые комнаты и все живые турниры реестра.

  Существуют ради панели администратора: витрине хватает пулов лобби, а
  надзору нужны и те комнаты, которых в пуле нет, — столы идущего MTT
  принадлежат турниру, а не лобби.
  """
  @spec live_tables() :: [{Ecto.UUID.t(), pid()}]
  def live_tables, do: select_kind(:table)

  @spec live_tournaments() :: [{Ecto.UUID.t(), pid()}]
  def live_tournaments, do: select_kind(:tournament)

  defp select_kind(kind) do
    Registry.select(__MODULE__, [
      {{{kind, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}
    ])
  end

  @spec whereis(Ecto.UUID.t()) :: pid() | nil
  def whereis(room_id) do
    case Registry.lookup(__MODULE__, {:table, room_id}) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end
end
