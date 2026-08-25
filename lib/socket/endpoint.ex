defmodule Socket.Endpoint do
  use Phoenix.Endpoint, otp_app: :block_poker

  # Основной канал связи с клиентом. Аутентификация соединения — в UserSocket.
  socket "/socket", Socket.UserSocket,
    websocket: [
      connect_info: [:peer_data, :x_headers],
      error_handler: {Socket.UserSocket, :handle_error, []}
    ],
    longpoll: false

  # Панель администратора: отдельный сокет по отдельному пути и с
  # отдельной солью токена. Игровой `UserSocket` этим не затрагивается
  # вообще (§6 задачи 8).
  socket "/admin/socket", Socket.AdminSocket,
    websocket: [
      connect_info: [:peer_data, :x_headers],
      error_handler: {Socket.AdminSocket, :handle_error, []}
    ],
    longpoll: false

  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :block_poker
  end

  # Файлы автообновления клиента — до парсеров и роутера: это статика,
  # и разбирать её тело как JSON незачем (§3 задачи 34).
  plug Api.Plugs.ClientUpdates

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # Загрузка сборки клиента: своё тело, свой предел размера. Стоит до
  # общего парсера и срабатывает ровно на одной ручке (§3 задачи 34).
  plug Api.Plugs.ClientReleaseUpload

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.Head

  # CORS панели — до роутера: предполётный `OPTIONS` не имеет маршрута,
  # и в пайплайне роутера этот плаг для него не выполнялся бы вовсе.
  plug Api.Plugs.AdminCors

  # HTTP-слой намеренно тощий: только то, что нельзя сделать по сокету.
  plug Api.Router
end
