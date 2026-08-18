defmodule Socket.ChannelCase do
  @moduledoc """
  Тест-кейс для каналов: путь целиком от входящего сообщения до push'а клиенту.
  Тесты с несколькими подключёнными сокетами требуют `async: false`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint Socket.Endpoint

      import Phoenix.ChannelTest
      import Socket.ChannelCase
    end
  end

  setup tags do
    BlockPoker.DataCase.setup_sandbox(tags)
    :ok
  end
end
