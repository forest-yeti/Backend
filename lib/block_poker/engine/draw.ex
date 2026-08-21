defmodule BlockPoker.Engine.Draw do
  @moduledoc """
  Доезд: незакрытая комбинация и карты, которые её закрывают.

  Тип — это **название** того, что видно в картах, а не источник истины.
  Считается доезд перебором карт, которые реально доводят руку до стрита
  или флеша (`cards`), и уже по ним получает имя: одна закрывающая
  величина — гатшот, две по краям четырёх подряд — двусторонка, две
  внутри — двойной гатшот. Обратный порядок («узнали шаблон — приписали
  восемь аутов») врёт всякий раз, когда часть карт уже вышла на борде.
  """

  alias BlockPoker.Engine.Card

  @type type :: :flush_draw | :straight_flush_draw | :open_ended | :double_gutshot | :gutshot

  @enforce_keys [:type, :cards, :outs]
  defstruct [:type, :cards, :outs]

  @type t :: %__MODULE__{
          type: type(),
          cards: [Card.t()],
          outs: pos_integer()
        }
end
