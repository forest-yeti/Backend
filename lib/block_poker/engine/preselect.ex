defmodule BlockPoker.Engine.Preselect do
  @moduledoc """
  Заранее выбранное действие: игрок нажимает кнопку до своего хода, и стол
  ходит за него, как только очередь доходит.

  Без этого мультитейблинг невозможен физически: за восемью столами нельзя
  успеть везде, а «мусор на префлопе» решается ещё до того, как соперники
  доиграли. Поэтому правило общее для кэша, турнира и sit-n-go — оно про
  порядок хода, а не про формат игры.

  Варианты ровно те, что имеют смысл до чужих действий:

    * `:fold` — сбросить, что бы ни произошло;
    * `:check_fold` — чек, если бесплатно, иначе сброс;
    * `:check` — чек, если бесплатно, **иначе выбор снимается** и игрок
      ходит сам;
    * `:call_any` — заплатить сколько попросят (бесплатно — просто чек).

  Разница между `:check` и `:check_fold` — не мелочь, а вся суть механики:
  первый защищает от случайного сброса руки, которую перебили ставкой,
  второй как раз для мусора, с которым разговаривать не о чем.

  Выбор действует **только на текущее решение**. Новая улица, новая раздача
  или снятый выбор — и стол снова ждёт игрока. Живущий дольше выбор был бы
  ловушкой: обстановка на флопе не та, в которой его делали.

  Модуль чистый: он сопоставляет выбор с легальными действиями и говорит,
  что из этого следует. Кто и когда его позовёт, решает стол.
  """

  @type t :: :fold | :check | :check_fold | :call_any

  @type decision :: {:act, :fold | :check | :call} | :cancel

  @choices [:fold, :check, :check_fold, :call_any]

  @spec choices() :: [t()]
  def choices, do: @choices

  @doc """
  Разбор выбора клиента. `nil`, `"none"` и `"clear"` — снятие выбора:
  отдельного сообщения на отмену не нужно, это тот же выбор со значением
  «ничего».
  """
  @spec parse(term()) :: {:ok, t() | nil} | {:error, :validation_failed}
  def parse(nil), do: {:ok, nil}
  def parse(value) when value in ["none", "clear", ""], do: {:ok, nil}

  def parse(value) when is_binary(value) do
    case Enum.find(@choices, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :validation_failed}
      choice -> {:ok, choice}
    end
  end

  def parse(value) when value in @choices, do: {:ok, value}
  def parse(_value), do: {:error, :validation_failed}

  @doc """
  Что делать, когда очередь дошла до игрока.

  Легальные действия берутся у раздачи, а не выводятся здесь заново:
  единственный источник правды о допустимом ходе — `Engine.Hand`.
  """
  @spec resolve(t() | nil, map()) :: decision() | :none
  def resolve(nil, _legal), do: :none

  def resolve(:fold, _legal), do: {:act, :fold}

  def resolve(:check_fold, legal) do
    if free?(legal), do: {:act, :check}, else: {:act, :fold}
  end

  # Ставка пришла после того, как игрок нажал «чек»: сбрасывать руку за него
  # никто не просил, поэтому выбор снимается и решение возвращается игроку.
  def resolve(:check, legal) do
    if free?(legal), do: {:act, :check}, else: :cancel
  end

  def resolve(:call_any, legal) do
    cond do
      is_integer(legal[:call]) and legal[:call] > 0 -> {:act, :call}
      free?(legal) -> {:act, :check}
      true -> :cancel
    end
  end

  def resolve(_choice, _legal), do: :cancel

  defp free?(legal), do: Map.get(legal, :check) == true
end
