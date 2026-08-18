defmodule BlockPoker.Engine.EquityResult do
  @moduledoc """
  Результат расчёта эквити.

  `win` — доля раскладов, выигранных единолично, `tie` — доля раскладов
  с делением банка, `equity` — доля самого банка: `win + tie / (число делящих)`.
  Игроку показывают именно `equity`: половина банка на ничьей — это половина
  банка, а не победа.
  """

  alias BlockPoker.Engine.Out

  @enforce_keys [:players, :simulations, :mode]
  defstruct [:players, :simulations, :mode]

  @type player :: %{
          id: term(),
          win: float(),
          tie: float(),
          equity: float(),
          outs: [Out.t()]
        }

  @type t :: %__MODULE__{
          players: [player()],
          simulations: pos_integer(),
          mode: :exact | :monte_carlo
        }
end
