defmodule BlockPoker.Engine.Discipline.Registry do
  @moduledoc """
  Реестр дисциплин: единственный файл, который меняется при добавлении новой.

  Тесты подмешивают свои дисциплины не через реестр, а передавая модуль
  напрямую, — реестр нужен там, где дисциплина приходит из шаблона стола
  строкой.
  """

  alias BlockPoker.Engine.{Discipline, Hand}

  @disciplines [Hand]
  @by_id Map.new(@disciplines, &{&1.id(), &1})

  @spec all() :: [Discipline.t()]
  def all, do: @disciplines

  @spec ids() :: [atom()]
  def ids, do: Enum.map(@disciplines, & &1.id())

  @spec default() :: Discipline.t()
  def default, do: Hand

  @spec fetch(atom() | String.t()) :: {:ok, Discipline.t()} | {:error, :unknown_discipline}
  def fetch(id) when is_atom(id) do
    case Map.fetch(@by_id, id) do
      {:ok, discipline} -> {:ok, discipline}
      :error -> {:error, :unknown_discipline}
    end
  end

  def fetch(id) when is_binary(id) do
    case Enum.find(@by_id, fn {known, _module} -> Atom.to_string(known) == id end) do
      {_id, discipline} -> {:ok, discipline}
      nil -> {:error, :unknown_discipline}
    end
  end

  @spec fetch!(atom() | String.t()) :: Discipline.t()
  def fetch!(id) do
    case fetch(id) do
      {:ok, discipline} ->
        discipline

      {:error, :unknown_discipline} ->
        raise ArgumentError, "неизвестная дисциплина: #{inspect(id)}"
    end
  end
end
