defmodule Socket.Protocol.Version do
  @moduledoc """
  Версия прикладного протокола — согласуется при `connect` (§5 CLAUDE.md).

  Параметр называется `protocol_vsn`, а не `vsn`: `vsn` занят самим
  Phoenix-транспортом под версию его wire-формата.
  """

  @current "1"
  @supported ["1"]

  @spec current() :: String.t()
  def current, do: @current

  @spec supported() :: [String.t()]
  def supported, do: @supported

  @doc "Версия не передана — считаем текущей: клиент старше протокола не бывает."
  @spec check(String.t() | nil) :: :ok | {:error, :unsupported_protocol_version}
  def check(nil), do: :ok
  def check(vsn) when vsn in @supported, do: :ok
  def check(_vsn), do: {:error, :unsupported_protocol_version}
end
