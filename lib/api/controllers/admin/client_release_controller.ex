defmodule Api.Admin.ClientReleaseController do
  @moduledoc """
  Сборки клиента: список, загрузка, публикация, удаление.

  Единственная ручка панели, принимающая файл. Транспорту здесь достаётся
  ровно его пять дел (§3 CLAUDE.md): разобрать multipart, достать из
  `conn.assigns` личность администратора, позвать одну функцию контекста
  и отрендерить результат. Ни версия, ни хэш, ни имя файла на диске здесь
  не вычисляются — всё это решает `BlockPoker.ClientReleases`.
  """

  use Api, :controller

  alias BlockPoker.Admin

  action_fallback Api.FallbackController

  def index(conn, _params) do
    with {:ok, releases} <- Admin.client_releases(conn.assigns.admin_ctx) do
      render(conn, :index, releases: releases)
    end
  end

  def create(conn, params) do
    with {:ok, upload} <- fetch_upload(params),
         {:ok, release} <-
           Admin.upload_client_release(conn.assigns.admin_ctx, %{
             version: params["version"],
             mandatory: truthy?(params["mandatory"]),
             notes: params["notes"],
             path: upload.path,
             original_name: upload.filename
           }) do
      conn
      |> put_status(:created)
      |> render(:show, release: release)
    end
  end

  def publish(conn, %{"id" => id}) do
    with {:ok, release} <- Admin.publish_client_release(conn.assigns.admin_ctx, id) do
      render(conn, :show, release: release)
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- Admin.delete_client_release(conn.assigns.admin_ctx, id) do
      send_resp(conn, :no_content, "")
    end
  end

  defp fetch_upload(%{"file" => %Plug.Upload{} = upload}), do: {:ok, upload}
  defp fetch_upload(_params), do: {:error, :release_file_required}

  # Форма шлёт флаг строкой: `multipart/form-data` не знает булевых типов.
  defp truthy?(value), do: value in [true, "true", "1", "on"]
end
