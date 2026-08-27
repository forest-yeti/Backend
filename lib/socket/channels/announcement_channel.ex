defmodule Socket.Channels.AnnouncementChannel do
  @moduledoc """
  Топик `announcements`: объявления администрации всем игрокам.

  Канал существует потому, что общего топика «все подключённые» в системе
  не было: лобби, стол, турнир и кошелёк — это подписки на конкретный
  предмет, и игрок за столом не подписан ни на одно лобби. Объявление же
  адресовано всем и не связано ни с одной комнатой.

  Подписка открыта любому аутентифицированному соединению: содержимое
  объявления одинаково для всех, приватного в нём ничего нет.

  Клиент присылать сюда ничего не может — канал односторонний.
  """

  use Phoenix.Channel

  alias BlockPoker.Announcements

  @impl true
  def join("announcements", _payload, socket) do
    :ok = Phoenix.PubSub.subscribe(BlockPoker.PubSub, Announcements.topic())
    {:ok, socket}
  end

  # Объявление приходит из контекста готовым набором фактов — рендерить
  # в нём нечего, кроме приведения времени к строке.
  @impl true
  def handle_info({:announcement, announcement}, socket) do
    push(socket, "announcement", %{
      id: announcement.id,
      title: announcement.title,
      text: announcement.text,
      at: DateTime.to_iso8601(announcement.at)
    })

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}
end
