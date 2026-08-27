defmodule Api.Plugs.BannerUpload do
  @moduledoc """
  Разбор `multipart` только для загрузки картинки баннера.

  Отдельный плаг по тем же соображениям, что и
  `Api.Plugs.ClientReleaseUpload`, но с обратным знаком: общий парсер
  `multipart` не понимает вовсе, а поднимать предел тела до размеров
  сборки клиента ради картинки — значит открыть ещё одну ручку, которой
  можно забить диск. Предел здесь свой и маленький.

  Плаг стоит **до** общего `Plug.Parsers` и срабатывает ровно на одном
  методе и пути.
  """

  @behaviour Plug

  @path ["admin", "banners"]

  # 6 МБ: доменный предел картинки — 5 МБ (`Banners.Storage`), запас
  # покрывает служебные части multipart. Тело больше этого обрывается
  # разбором, и до контекста дело не доходит.
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
