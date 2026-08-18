defmodule Socket.UserSocketTest do
  use Socket.ChannelCase, async: true

  import BlockPoker.AccountsFixtures

  alias BlockPoker.Accounts
  alias Socket.UserSocket

  defp token_for(user) do
    {:ok, session} = Accounts.login(user.email, valid_password())
    session.token
  end

  test "валидный токен пускает и кладёт user_id в assigns" do
    user = user_fixture()

    assert {:ok, socket} = connect(UserSocket, %{"token" => token_for(user)})
    assert socket.assigns.user_id == user.id
    assert socket.assigns.protocol_vsn == Socket.Protocol.Version.current()
  end

  test "в assigns нет ничего, кроме личности и версии протокола" do
    user = user_fixture()

    {:ok, socket} = connect(UserSocket, %{"token" => token_for(user)})

    assert Map.keys(socket.assigns) |> Enum.sort() == [:protocol_vsn, :user_id]
  end

  test "подделанный токен — отказ в handshake" do
    assert {:error, %{code: "token_invalid"}} = connect(UserSocket, %{"token" => "поддельный"})
  end

  test "просроченный токен — отказ в handshake" do
    user = user_fixture()
    expired = Phoenix.Token.sign(Socket.Endpoint, "user socket", user.id, signed_at: 0)

    assert {:error, %{code: "token_expired"}} = connect(UserSocket, %{"token" => expired})
  end

  test "токен не передан — отказ" do
    assert {:error, %{code: "token_invalid"}} = connect(UserSocket, %{})
  end

  test "несовместимая версия протокола — отказ с понятным кодом" do
    user = user_fixture()

    assert {:error, %{code: "unsupported_protocol_version"}} =
             connect(UserSocket, %{"token" => token_for(user), "protocol_vsn" => "999"})
  end

  test "заблокированный игрок не открывает соединение" do
    user = user_fixture()
    token = token_for(user)

    user
    |> Ecto.Changeset.change(status: :blocked)
    |> BlockPoker.Repo.update!()

    assert {:error, %{code: "user_blocked"}} = connect(UserSocket, %{"token" => token})
  end
end
