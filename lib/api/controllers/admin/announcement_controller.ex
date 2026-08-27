defmodule Api.Admin.AnnouncementController do
  @moduledoc """
  Объявление всем игрокам: `POST /admin/announcements`.

  Транспорт достаёт личность администратора из `conn.assigns`, зовёт одну
  функцию контекста и рендерит результат. Ни проверка текста, ни рассылка,
  ни запись в журнал сюда не относятся.

  Ручка HTTP, а не сообщение админского сокета, по тому же признаку, что и
  остальные операции панели: это разовое действие с ответом, а не поток
  событий. Пуш здесь нужен игрокам, а не панели.
  """

  use Api, :controller

  alias BlockPoker.Admin

  action_fallback Api.FallbackController

  def create(conn, params) do
    with {:ok, announcement} <-
           Admin.announce(conn.assigns.admin_ctx, %{
             title: params["title"],
             text: params["text"]
           }) do
      conn
      |> put_status(:created)
      |> json(%{
        id: announcement.id,
        title: announcement.title,
        text: announcement.text,
        at: DateTime.to_iso8601(announcement.at)
      })
    end
  end
end
