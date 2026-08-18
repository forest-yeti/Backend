defmodule Socket do
  @moduledoc """
  Точка входа транспортного слоя реального времени.

  Слой `socket` — тонкий: разбирает входящие сообщения, вызывает публичные
  функции контекстов ядра (`BlockPoker.*`) и сериализует результат для
  конкретного получателя. Бизнес-логики здесь нет — см. §3 CLAUDE.md.

      use Socket, :channel
  """

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
