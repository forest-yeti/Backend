defmodule BlockPoker.Engine.Rng.Seeded do
  @moduledoc """
  Воспроизводимый поток байт: `SHA-256(seed || counter)`.

  Нужен там, где результат обязан повторяться — тесты раздачи и чанки
  Монте-Карло. Взят хэш, а не `:rand`, чтобы запрет на `:rand` для карт
  (§9 CLAUDE.md) не приходилось оговаривать исключениями.
  """

  @behaviour BlockPoker.Engine.Rng

  @impl true
  def init(seed), do: {normalize(seed), 0, <<>>}

  @impl true
  def bytes({key, counter, buffer}, count) do
    {buffer, counter} = fill(buffer, counter, key, count)
    <<taken::binary-size(^count), rest::binary>> = buffer
    {taken, {key, counter, rest}}
  end

  defp fill(buffer, counter, _key, count) when byte_size(buffer) >= count do
    {buffer, counter}
  end

  defp fill(buffer, counter, key, count) do
    block = :crypto.hash(:sha256, <<key::binary, counter::unsigned-integer-64>>)
    fill(buffer <> block, counter + 1, key, count)
  end

  defp normalize(seed) when is_binary(seed), do: seed
  defp normalize(seed), do: :erlang.term_to_binary(seed)
end
