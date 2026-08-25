defmodule Socket.ClientVersionGateTest do
  @moduledoc """
  Гейт версии клиентской сборки на handshake.

  Модуль намеренно `async: false`: тесты двигают глобальный
  `:client_release`, а от него зависит **любое** подключение сокета.
  В async-модуле поднятый минимум отверг бы соединения чужих тестов,
  которые про `client_vsn` ничего не знают.
  """

  use Socket.ChannelCase, async: false

  import BlockPoker.AccountsFixtures

  alias BlockPoker.Accounts
  alias Socket.UserSocket

  setup do
    previous = Application.get_env(:block_poker, :client_release, [])
    BlockPoker.ClientReleases.Feed.reset()
    Application.put_env(:block_poker, :client_release, current: "1.4.2", minimum: "1.4.0")

    on_exit(fn ->
      Application.put_env(:block_poker, :client_release, previous)
      BlockPoker.ClientReleases.Feed.reset()
    end)

    :ok
  end

  defp token_for(user) do
    {:ok, session} = Accounts.login(user.email, valid_password())
    session.token
  end

  test "устаревшая сборка — отказ в handshake" do
    user = user_fixture()

    assert {:error, %{code: "client_too_old"}} =
             connect(UserSocket, %{"token" => token_for(user), "client_vsn" => "1.3.0"})
  end

  test "актуальная сборка пускается" do
    user = user_fixture()

    assert {:ok, socket} =
             connect(UserSocket, %{"token" => token_for(user), "client_vsn" => "1.4.2"})

    assert socket.assigns.user_id == user.id
  end

  test "сборка между минимумом и актуальной играет" do
    user = user_fixture()

    assert {:ok, _socket} =
             connect(UserSocket, %{"token" => token_for(user), "client_vsn" => "1.4.1"})
  end

  test "устаревшая сборка отсекается раньше токена" do
    assert {:error, %{code: "client_too_old"}} =
             connect(UserSocket, %{"token" => "поддельный", "client_vsn" => "1.0.0"})
  end

  test "сборка без client_vsn при поднятом минимуме не проходит" do
    user = user_fixture()

    assert {:error, %{code: "client_too_old"}} =
             connect(UserSocket, %{"token" => token_for(user)})
  end
end
