defmodule Socket.Channels.AnnouncementChannelTest do
  @moduledoc """
  Объявление насквозь: отправка из панели → push всем подключённым.

  Проверяется в том числе то, чего у объявления нет: оно не хранится и
  не догоняет тех, кто подключился после отправки.
  """

  use Socket.ChannelCase, async: false

  import BlockPoker.AccountsFixtures
  import BlockPoker.AdminFixtures

  alias BlockPoker.Admin
  alias Socket.UserSocket

  defp connect_announcements(user) do
    {:ok, %{token: token}} = BlockPoker.Accounts.start_session(user)
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    subscribe_and_join(socket, "announcements", %{})
  end

  test "объявление доходит до всех подключённых игроков" do
    %{ctx: ctx} = admin_with_ctx()

    {:ok, _reply, _first} = connect_announcements(user_fixture())
    {:ok, _reply, _second} = connect_announcements(user_fixture())

    {:ok, sent} =
      Admin.announce(ctx, %{title: "Технические работы", text: "Через 15 минут"})

    # Два подключённых сокета — два push'а в один тест-процесс.
    assert_push "announcement", %{id: id, title: "Технические работы", text: "Через 15 минут"}
    assert_push "announcement", %{id: ^id}
    assert id == sent.id
  end

  test "подключившийся после отправки ничего не получает: объявление не хранится" do
    %{ctx: ctx} = admin_with_ctx()

    {:ok, _sent} = Admin.announce(ctx, %{text: "Через 15 минут"})

    {:ok, _reply, _channel} = connect_announcements(user_fixture())

    refute_push "announcement", %{}
  end

  test "заголовок необязателен" do
    %{ctx: ctx} = admin_with_ctx()
    {:ok, _reply, _channel} = connect_announcements(user_fixture())

    {:ok, _sent} = Admin.announce(ctx, %{text: "Просто текст"})

    assert_push "announcement", %{title: nil, text: "Просто текст"}
  end

  test "пустой текст не рассылается" do
    %{ctx: ctx} = admin_with_ctx()
    {:ok, _reply, _channel} = connect_announcements(user_fixture())

    assert {:error, :announcement_text_required} = Admin.announce(ctx, %{text: "   "})

    refute_push "announcement", %{}
  end

  test "время приводится к строке: канал отдаёт то, что уйдёт в сокет" do
    %{ctx: ctx} = admin_with_ctx()
    {:ok, _reply, _channel} = connect_announcements(user_fixture())

    {:ok, _sent} = Admin.announce(ctx, %{text: "Через 15 минут"})

    assert_push "announcement", %{at: at}
    assert {:ok, _at, _offset} = DateTime.from_iso8601(at)
  end
end
