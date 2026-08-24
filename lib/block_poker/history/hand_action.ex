defmodule BlockPoker.History.HandAction do
  @moduledoc """
  Упорядоченный лог действий раздачи: материал реплея и разбора жалоб.

  Вынужденные ставки пишутся такими же строками, как и решения игроков.
  Иначе реплей начинается с необъяснимого банка, а VPIP приходится
  считать вычитанием блайндов из вложенного.

  Источник — тот же список событий, который уходит в broadcast (§7
  CLAUDE.md): одни и те же факты, два потребителя. Второго источника
  правды о ходе раздачи в проекте нет.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BlockPoker.History.HandRecord

  @type t :: %__MODULE__{}

  @streets [:preflop, :flop, :turn, :river]
  @actions [
    :post_blind,
    :post_ante,
    :post,
    :dead_post,
    :straddle,
    :fold,
    :check,
    :call,
    :bet,
    :raise,
    :all_in
  ]

  @primary_key false
  @foreign_key_type :binary_id
  schema "hand_actions" do
    belongs_to :hand, HandRecord, primary_key: true
    field :seq, :integer, primary_key: true

    field :street, Ecto.Enum, values: @streets
    field :seat, :integer
    field :action, Ecto.Enum, values: @actions

    # `amount` — вложено этим действием, `to_amount` — итоговая ставка
    # улицы после него: реплею не приходится пересчитывать ни то, ни другое.
    field :amount, :integer, default: 0
    field :to_amount, :integer, default: 0
    field :pot_before, :integer, default: 0
    field :stack_after, :integer, default: 0

    field :elapsed_ms, :integer, default: 0

    # Сработал преселект или таймаут, а не живое решение.
    field :auto, :boolean, default: false
  end

  @spec streets() :: [atom()]
  def streets, do: @streets

  @spec actions() :: [atom()]
  def actions, do: @actions

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(action, attrs) do
    action
    |> cast(attrs, [
      :hand_id,
      :seq,
      :street,
      :seat,
      :action,
      :amount,
      :to_amount,
      :pot_before,
      :stack_after,
      :elapsed_ms,
      :auto
    ])
    |> validate_required([:hand_id, :seq, :street, :seat, :action])
  end
end
