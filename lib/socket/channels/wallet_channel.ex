defmodule Socket.Channels.WalletChannel do
  @moduledoc """
  Топик `wallet:<user_id>`: баланс игрока и его изменения.

  Канал нужен потому, что до него баланс уходил клиенту **один раз** —
  в ответе на `login`, — и любой бай-ин молча разводил экран с базой:
  игрок видел сумму часовой давности и получал `insufficient_funds` на
  кнопку, которая по его данным должна была сработать.

  Свой кошелёк и только свой: топик сверяется с `socket.assigns.user_id`.
  Идентичность берётся из соединения, а не из имени топика, — иначе
  подписаться на чужой кошелёк можно было бы строкой в `join`.
  """

  use Phoenix.Channel

  alias BlockPoker.Wallet
  alias Socket.Protocol.Message
  alias Socket.Views.WalletView

  @impl true
  def join("wallet:" <> user_id, _payload, socket) do
    if user_id == socket.assigns.user_id do
      :ok = Phoenix.PubSub.subscribe(BlockPoker.PubSub, Wallet.topic(user_id))
      {:ok, WalletView.render(Wallet.list_wallets(user_id)), socket}
    else
      {:error, Message.error(:not_found)}
    end
  end

  # Явный перезапрос: клиенту незачем ждать события, если он усомнился
  # в своей цифре — например, получив отказ по деньгам.
  @impl true
  def handle_in("balance", _payload, socket) do
    {:reply, {:ok, WalletView.render(Wallet.list_wallets(socket.assigns.user_id))}, socket}
  end

  # Событие приходит из контекста уже готовым: это набор фактов о движении
  # денег, а не схема журнала. Рендерить в нём нечего.
  @impl true
  def handle_info({:wallet_entry, payload}, socket) do
    push(socket, "wallet_entry", payload)
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}
end
