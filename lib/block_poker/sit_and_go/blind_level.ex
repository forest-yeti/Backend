defmodule BlockPoker.SitAndGo.BlindLevel do
  @moduledoc """
  Один уровень структуры турнира.

  Три номинала вместо двух — потому что вид покера решает, какой из них
  живой: холдем играется на блайндах, Short Deck — на анте кнопки. Причина
  и следствия описаны в `Engine.BlindSchedule`; схема их только хранит.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BlockPoker.Engine.BlindSchedule

  @type t :: %__MODULE__{}

  @editable [:level, :small_blind, :big_blind, :ante, :duration_seconds]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "sit_n_go_blind_levels" do
    belongs_to :setting, BlockPoker.SitAndGo.SitAndGoSetting, foreign_key: :sit_n_go_setting_id

    field :level, :integer
    field :small_blind, :integer, default: 0
    field :big_blind, :integer, default: 0
    field :ante, :integer, default: 0
    field :duration_seconds, :integer

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(level, attrs) do
    level
    |> cast(attrs, @editable)
    |> validate_required([:level, :duration_seconds])
    |> validate_number(:level, greater_than: 0)
    |> validate_number(:duration_seconds, greater_than: 0)
    |> validate_number(:small_blind, greater_than_or_equal_to: 0)
    |> validate_number(:big_blind, greater_than_or_equal_to: 0)
    |> validate_number(:ante, greater_than_or_equal_to: 0)
    |> validate_playable()
    |> unique_constraint([:sit_n_go_setting_id, :level])
    |> check_constraint(:level, name: :sit_n_go_blind_levels_amounts)
  end

  # Уровень, где нечего платить, остановил бы турнир: стеки перестали бы
  # двигаться сами, а Sit & Go обязан заканчиваться победителем.
  defp validate_playable(changeset) do
    big = get_field(changeset, :big_blind) || 0
    ante = get_field(changeset, :ante) || 0

    if big > 0 or ante > 0 do
      changeset
    else
      add_error(changeset, :big_blind, "уровень должен нести большой блайнд или анте")
    end
  end

  @doc "Строка уровня как её видит `Engine.BlindSchedule`."
  @spec to_schedule(t()) :: BlindSchedule.level()
  def to_schedule(%__MODULE__{} = level) do
    %{
      level: level.level,
      small_blind: level.small_blind,
      big_blind: level.big_blind,
      ante: level.ante,
      duration_seconds: level.duration_seconds
    }
  end
end
