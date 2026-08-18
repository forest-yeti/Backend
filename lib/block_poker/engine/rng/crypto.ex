defmodule BlockPoker.Engine.Rng.Crypto do
  @moduledoc """
  Боевой RNG: `:crypto.strong_rand_bytes/1`. Состояния нет — источник
  системный, seed игнорируется.
  """

  @behaviour BlockPoker.Engine.Rng

  @impl true
  def init(_seed), do: nil

  @impl true
  def bytes(state, count), do: {:crypto.strong_rand_bytes(count), state}
end
