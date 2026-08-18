defmodule Api.ConnCase do
  @moduledoc """
  Тест-кейс для HTTP-слоя. Sandbox поднимается через `BlockPoker.DataCase`,
  каждый тест идёт в транзакции и откатывается.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint Socket.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Api.ConnCase
    end
  end

  setup tags do
    BlockPoker.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
