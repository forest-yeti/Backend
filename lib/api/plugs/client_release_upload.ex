defmodule Api.Plugs.ClientReleaseUpload do
  @moduledoc """
  Разбор `multipart` только для загрузки сборки клиента.

  Отдельный плаг, а не опции общего `Plug.Parsers`, потому что предел
  размера тела здесь на три порядка больше обычного: инсталлятор весит
  сотни мегабайт, а любая другая ручка панели с телом такого размера —
  это атака, и общий предел поднимать под неё нельзя.

  Плаг стоит **до** общего `Plug.Parsers` и срабатывает ровно на одном
  методе и пути. Разобранное тело общий парсер не трогает.
  """

  @behaviour Plug

  @path ["admin", "client-releases"]

  # Гигабайт — заведомо больше любой реальной сборки Electron и заведомо
  # меньше того, чем можно забить диск одним запросом.
  @max_bytes 1_000_000_000

  @parser Plug.Parsers.init(
            parsers: [:multipart],
            pass: ["multipart/form-data"],
            length: @max_bytes,
            read_length: 1_000_000,
            read_timeout: 60_000
          )

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST", path_info: @path} = conn, _opts) do
    Plug.Parsers.call(conn, @parser)
  end

  def call(conn, _opts), do: conn
end
