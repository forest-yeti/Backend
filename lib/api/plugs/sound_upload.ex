defmodule Api.Plugs.SoundUpload do
  @moduledoc """
  Разбор `multipart` только для загрузки звука.

  Отдельный плаг по тем же соображениям, что и `Api.Plugs.BannerUpload`:
  общий парсер `multipart` не понимает вовсе, а поднимать предел тела
  для всех ручек ради одной — значит открыть ещё один способ забить диск.

  Плаг стоит **до** общего `Plug.Parsers` и срабатывает ровно на одном
  методе и пути.
  """

  @behaviour Plug

  @path ["admin", "sounds"]

  # 6 МБ: доменный предел файла — 5 МБ (`Sounds.Storage`), запас
  # покрывает служебные части multipart.
  @max_bytes 6_000_000

  @parser Plug.Parsers.init(
            parsers: [:multipart],
            pass: ["multipart/form-data"],
            length: @max_bytes,
            read_length: 1_000_000,
            read_timeout: 30_000
          )

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST", path_info: @path} = conn, _opts) do
    Plug.Parsers.call(conn, @parser)
  end

  def call(conn, _opts), do: conn
end
