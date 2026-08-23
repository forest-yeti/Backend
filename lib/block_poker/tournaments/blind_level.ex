defmodule BlockPoker.Tournaments.BlindLevel do
  @moduledoc """
  Один уровень структуры турнира.

  По форме — один в один с уровнем Sit & Go: три номинала, потому что вид
  покера решает, какой из них живой (холдем — блайнды, Short Deck — анте
  кнопки). Отличие в двух флагах.

  `rebuy_allowed` значит шире, чем звучит: «можно ли **ещё войти** в этот
  турнир». Одно правило и для поздней регистрации, и для возврата
  выбывшего — второй источник правды о том же моменте был бы багом.

  ## Анте здесь классическое

  Поля `ante_type` нет: BB-анте (когда за всех платит большой блайнд)
  в турнирах не используется. Это решение, а не умолчание. BB-анте требует
  отдельного правила для короткого стека на большом блайнде — он не может
  заплатить анте целиком, и рум обязан решить, что происходит с недостачей.
  Классическое анте такого случая не создаёт: каждый платит из своего стека
  сколько может, и это уже умеет `Engine.Betting`.

  ## Перерыва здесь нет

  Перерыв привязан не к уровню, а к часам: каждый час в `XX:55`
  (`Engine.TournamentBreak`). Хранить его ещё и в строке уровня значило бы
  завести второй источник правды о том, когда турнир стоит.

  `addon_allowed` при этом остаётся свойством уровня: аддон **разрешён**
  на уровне, а **берётся** на ближайшем перерыве внутри него — то есть на
  пересечении двух правил, а не на новом поле.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BlockPoker.Engine.BlindSchedule

  @type t :: %__MODULE__{}

  @editable [
    :level,
    :small_blind,
    :big_blind,
    :ante,
    :duration_seconds,
    :rebuy_allowed,
    :addon_allowed
  ]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tournament_blind_levels" do
    belongs_to :setting, BlockPoker.Tournaments.TournamentSetting,
      foreign_key: :tournament_setting_id

    field :level, :integer
    field :small_blind, :integer, default: 0
    field :big_blind, :integer, default: 0
    field :ante, :integer, default: 0
    field :duration_seconds, :integer

    field :rebuy_allowed, :boolean, default: false
    field :addon_allowed, :boolean, default: false

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
    |> unique_constraint([:tournament_setting_id, :level])
    |> check_constraint(:level, name: :tournament_blind_levels_amounts)
  end

  # Уровень, где нечего платить, остановил бы турнир: стеки перестали бы
  # двигаться сами, а турнир обязан заканчиваться победителем.
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

  @doc """
  Проверка набора уровней целиком — то, что не выразить ни constraint'ом,
  ни changeset'ом одной строки.

  Четыре свойства, и каждое ловит турнир, который нельзя доиграть:

    * уровни идут подряд с первого без дыр;
    * `rebuy_allowed` **монотонен**: разрешено на уровнях `1..k`, дальше
      запрещено. Турнир, где ребаи закрылись и снова открылись, — это не
      структура, а ошибка оператора;
    * последний уровень `rebuy_allowed = false` — иначе поздняя
      регистрация не закрывается никогда, и турнир не может закончиться;
    * `addon_allowed` разрешён максимум на одном уровне; при нулевой цене
      аддона — ни на одном.
  """
  @spec validate_set([t()], non_neg_integer()) :: :ok | {:error, atom()}
  def validate_set([], _addon_cost), do: {:error, :no_blind_levels}

  def validate_set(levels, addon_cost) do
    sorted = Enum.sort_by(levels, & &1.level)

    with :ok <- validate_contiguous(sorted),
         :ok <- validate_rebuy_monotonic(sorted),
         :ok <- validate_last_closes(sorted) do
      validate_addon_levels(sorted, addon_cost)
    end
  end

  defp validate_contiguous(sorted) do
    expected = Enum.to_list(1..length(sorted))

    if Enum.map(sorted, & &1.level) == expected, do: :ok, else: {:error, :levels_not_contiguous}
  end

  # Монотонность проверяется как «после первого запрета разрешений нет»:
  # так формулировка совпадает с тем, что оператор видит на экране.
  defp validate_rebuy_monotonic(sorted) do
    sorted
    |> Enum.drop_while(& &1.rebuy_allowed)
    |> Enum.any?(& &1.rebuy_allowed)
    |> case do
      true -> {:error, :rebuy_not_monotonic}
      false -> :ok
    end
  end

  defp validate_last_closes(sorted) do
    if List.last(sorted).rebuy_allowed, do: {:error, :rebuy_never_closes}, else: :ok
  end

  defp validate_addon_levels(sorted, addon_cost) do
    count = Enum.count(sorted, & &1.addon_allowed)

    cond do
      addon_cost == 0 and count > 0 -> {:error, :addon_without_cost}
      count > 1 -> {:error, :addon_on_many_levels}
      true -> :ok
    end
  end
end
