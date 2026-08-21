defmodule BlockPoker.SitAndGo.PrizeTier do
  @moduledoc """
  Строка лотерейной таблицы: множитель, его шанс и раскладка фонда по местам.

  Схема проверяет **строку**; свойства набора — что шансы суммируются
  в полную шкалу и что матожидание даёт заданный возврат — проверяет
  `Engine.PrizePool` и контекст, потому что constraint видит одну строку,
  а инвариант живёт в таблице целиком.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BlockPoker.Engine.PrizePool

  @type t :: %__MODULE__{}

  @editable [:multiplier, :chance_ppm, :payouts]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "sit_n_go_prize_tiers" do
    belongs_to :setting, BlockPoker.SitAndGo.SitAndGoSetting, foreign_key: :sit_n_go_setting_id

    field :multiplier, :integer
    field :chance_ppm, :integer
    field :payouts, {:array, :integer}

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(tier, attrs) do
    tier
    |> cast(attrs, @editable)
    |> validate_required(@editable)
    |> validate_number(:multiplier, greater_than: 0)
    |> validate_number(:chance_ppm,
      greater_than: 0,
      less_than_or_equal_to: PrizePool.chance_scale()
    )
    |> validate_payouts()
    |> unique_constraint([:sit_n_go_setting_id, :multiplier])
    |> check_constraint(:multiplier, name: :sit_n_go_prize_tiers_values)
  end

  # Доли обязаны складываться ровно в сотню и идти по убыванию: первое место
  # не может получить меньше второго, а недостача или излишек создавали бы
  # или уничтожали деньги мимо журнала.
  defp validate_payouts(changeset) do
    case get_field(changeset, :payouts) do
      nil ->
        changeset

      [] ->
        add_error(changeset, :payouts, "должно быть оплачено хотя бы одно место")

      payouts ->
        changeset
        |> validate_sum(payouts)
        |> validate_positive(payouts)
        |> validate_descending(payouts)
    end
  end

  defp validate_sum(changeset, payouts) do
    case Enum.sum(payouts) do
      100 ->
        changeset

      other ->
        add_error(changeset, :payouts, "доли мест должны складываться в 100, а не в #{other}")
    end
  end

  defp validate_positive(changeset, payouts) do
    if Enum.all?(payouts, &(&1 > 0)) do
      changeset
    else
      add_error(changeset, :payouts, "оплачиваемое место не может получить ноль")
    end
  end

  defp validate_descending(changeset, payouts) do
    if payouts == Enum.sort(payouts, :desc) do
      changeset
    else
      add_error(changeset, :payouts, "доли мест должны идти по убыванию")
    end
  end

  @doc "Строка тира как её видит `Engine.PrizePool`."
  @spec to_tier(t()) :: PrizePool.tier()
  def to_tier(%__MODULE__{} = tier) do
    %{multiplier: tier.multiplier, chance_ppm: tier.chance_ppm, payouts: tier.payouts}
  end

  @doc """
  Сколько мест оплачивает тир. Оно не может превышать число участников —
  это проверяет контекст, которому известен размер стола.
  """
  @spec paid_places(t()) :: pos_integer()
  def paid_places(%__MODULE__{payouts: payouts}), do: length(payouts)
end
