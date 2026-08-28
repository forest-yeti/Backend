defmodule Api.Admin.SoundJSON do
  @moduledoc """
  Рендер звуков панели.

  Карточка приходит из контекста готовой: панели остаётся отдать её как
  есть, приведя время к строке.
  """

  def index(%{sounds: sounds}), do: %{items: Enum.map(sounds, &render/1)}

  def show(%{sound: sound}), do: render(sound)

  def play(%{play: play}), do: Map.update!(play, :at, &at/1)

  defp render(sound), do: Map.update!(sound, :inserted_at, &at/1)

  defp at(nil), do: nil
  defp at(%DateTime{} = at), do: DateTime.to_iso8601(at)
end
