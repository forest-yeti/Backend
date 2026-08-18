defmodule BlockPoker.Engine.Variant.Registry do
  @moduledoc """
  Реестр вариантов: единственный файл, который меняется при добавлении
  нового вида покера. Тесты подмешивают свои варианты не через реестр,
  а передавая модуль напрямую, — реестр нужен там, где вид игры приходит
  из конфигурации стола строкой.
  """

  alias BlockPoker.Engine.Variant

  @variants [Variant.TexasHoldem]
  @by_id Map.new(@variants, &{&1.id(), &1})

  @spec all() :: [Variant.t()]
  def all, do: @variants

  @spec ids() :: [atom()]
  def ids, do: Map.keys(@by_id)

  @spec fetch(atom() | String.t()) :: {:ok, Variant.t()} | {:error, :unknown_variant}
  def fetch(id) when is_atom(id) do
    case Map.fetch(@by_id, id) do
      {:ok, variant} -> {:ok, variant}
      :error -> {:error, :unknown_variant}
    end
  end

  def fetch(id) when is_binary(id) do
    case Enum.find(@by_id, fn {known, _module} -> Atom.to_string(known) == id end) do
      {_id, variant} -> {:ok, variant}
      nil -> {:error, :unknown_variant}
    end
  end

  @spec fetch!(atom() | String.t()) :: Variant.t()
  def fetch!(id) do
    case fetch(id) do
      {:ok, variant} -> variant
      {:error, :unknown_variant} -> raise ArgumentError, "неизвестный вариант: #{inspect(id)}"
    end
  end
end
