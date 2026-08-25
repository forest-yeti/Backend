defmodule Api.Admin.GameJSON do
  @moduledoc """
  Рендер живых игр.

  Карточка приходит из ядра посчитанной целиком, включая `extra` со
  специфичными для режима полями: арифметики над фишками во view нет
  (§3 CLAUDE.md), и `case` по `kind` — тоже.
  """

  def index(%{games: games}), do: %{items: games}

  def show(%{game: game}), do: game
end
