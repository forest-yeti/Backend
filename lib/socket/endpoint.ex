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

  # Картинки баннеров — тоже статика и тоже до парсеров, по тем же
  # причинам: разбирать их тело как JSON незачем.
  plug Api.Plugs.BannerImages

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # CORS панели — до парсеров и до роутера. До роутера потому, что
  # предполётный `OPTIONS` маршрута не имеет и в пайплайн не попадает.
  # До парсеров — потому, что ответ об ошибке разбора тела (например,
  # слишком большая загрузка) тоже обязан нести эти заголовки: без них
  # браузер покажет отказ как ошибку CORS и спрячет настоящую причину.
  plug Api.Plugs.AdminCors

  # Загрузка сборки клиента: своё тело, свой предел размера. Стоит до
  # общего парсера и срабатывает ровно на одной ручке (§3 задачи 34).
  plug Api.Plugs.ClientReleaseUpload

  # Загрузка картинки баннера: свой multipart и свой — маленький —
  # предел размера. Общий парсер multipart не понимает вовсе.
  plug Api.Plugs.BannerUpload

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.Head

  # HTTP-слой намеренно тощий: только то, что нельзя сделать по сокету.
  plug Api.Router
end
