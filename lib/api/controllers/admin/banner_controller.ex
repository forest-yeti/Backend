defmodule Api.Admin.BannerController do
  @moduledoc """
  Баннеры: список мест, замена содержимого места, снятие баннера.

  Транспорту достаётся ровно его пять дел (§3 CLAUDE.md): разобрать
  multipart, достать личность администратора из `conn.assigns`, позвать
  одну функцию контекста и отрендерить результат. Ни список допустимых
  мест, ни имя файла на диске, ни адрес картинки здесь не вычисляются —
  всё это решает `BlockPoker.Banners`.

  Создания и редактирования тут не два действия, а одно: место — ключ, и
  `POST /admin/banners` кладёт баннер на место независимо от того, стоял
  там что-то раньше или нет.
  """

  use Api, :controller

  alias BlockPoker.Admin

  action_fallback Api.FallbackController

  def index(conn, _params) do
    with {:ok, banners} <- Admin.banners(conn.assigns.admin_ctx) do
      render(conn, :index, banners: banners)
    end
  end

  def create(conn, params) do
    with {:ok, banner} <-
           Admin.put_banner(conn.assigns.admin_ctx, %{
             place: params["place"],
             helper: blank_to_nil(params["helper"]),
             link: blank_to_nil(params["link"]),
             path: upload_path(params["image"])
           }) do
      render(conn, :show, banner: banner)
    end
  end

  def delete(conn, %{"place" => place}) do
    with :ok <- Admin.delete_banner(conn.assigns.admin_ctx, place) do
      send_resp(conn, :no_content, "")
    end
  end

  # Картинка необязательна: правка одних текстов оставляет прежнюю.
  defp upload_path(%Plug.Upload{path: path}), do: path
  defp upload_path(_absent), do: nil

  # `multipart/form-data` не знает `null`: пустое поле приходит пустой
  # строкой, а она значит «текста нет», а не «текст из нуля символов».
  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil
end
