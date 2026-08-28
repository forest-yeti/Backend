defmodule Api.Admin.SoundController do
  @moduledoc """
  Звуки администрации: библиотека и её воспроизведение.

  Транспорту достаётся ровно его пять дел (§3 CLAUDE.md): разобрать
  multipart, достать личность администратора из `conn.assigns`, позвать
  одну функцию контекста и отрендерить результат. Ни допустимые форматы
  файла, ни имя на диске, ни то, во сколько топиков развернётся «турнир»,
  здесь не решается — всё это знает `BlockPoker.Sounds`.

  Воспроизведение — `POST`, а не сообщение админского сокета, по тому же
  признаку, что и остальные операции панели: это разовое действие с
  ответом, а не поток событий. Пуш нужен игрокам, а не панели.
  """

  use Api, :controller

  alias Api.Admin.AdminParams
  alias BlockPoker.Admin

  action_fallback Api.FallbackController

  def index(conn, _params) do
    with {:ok, sounds} <- Admin.sounds(conn.assigns.admin_ctx) do
      render(conn, :index, sounds: sounds)
    end
  end

  def create(conn, params) do
    with {:ok, sound} <-
           Admin.upload_sound(conn.assigns.admin_ctx, %{
             title: params["title"],
             path: upload_path(params["file"])
           }) do
      conn
      |> put_status(:created)
      |> render(:show, sound: sound)
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- Admin.delete_sound(conn.assigns.admin_ctx, id) do
      send_resp(conn, :no_content, "")
    end
  end

  @doc "Звук всему залу: адресата в теле нет, он и есть смысл ручки."
  def play_everyone(conn, %{"id" => id}) do
    with {:ok, play} <- Admin.play_sound(conn.assigns.admin_ctx, :everyone, id) do
      render(conn, :play, play: play)
    end
  end

  @doc "Звук в конкретную игру из списка: комната или турнир целиком."
  def play_game(conn, %{"kind" => kind, "id" => id} = params) do
    with {:ok, kind} <- AdminParams.kind(kind),
         {:ok, play} <-
           Admin.play_sound(
             conn.assigns.admin_ctx,
             Admin.sound_target(kind, id),
             params["sound_id"]
           ) do
      render(conn, :play, play: play)
    end
  end

  defp upload_path(%Plug.Upload{path: path}), do: path
  defp upload_path(_absent), do: nil
end
