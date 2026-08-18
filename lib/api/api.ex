defmodule Api do
  @moduledoc """
  Точка входа тонкого HTTP-слоя.

  Здесь живёт только то, что физически нельзя сделать по сокету: регистрация,
  логин (выдача токена, которым авторизуется само соединение), обновление
  токена и healthcheck. Всё остальное — в `socket`. Бизнес-логики нет — см. §3
  CLAUDE.md.

      use Api, :router
      use Api, :controller
  """

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:json]

      import Plug.Conn
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
