defmodule BlockPoker.Engine.Out do
  @moduledoc """
  Аут, сгруппированный по рангу: «три туза» — это ранг и три конкретные карты.

  Группировка — представление; считается она из списка конкретных карт,
  а не наоборот, иначе «три туза» невозможно проверить прогоном.
  """

  alias BlockPoker.Engine.Card

  @enforce_keys [:rank, :cards, :count]
  defstruct [:rank, :cards, :count]

  @type t :: %__MODULE__{
          rank: Card.external_rank(),
          cards: [Card.t()],
          count: pos_integer()
        }
end
