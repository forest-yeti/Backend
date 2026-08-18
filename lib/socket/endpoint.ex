defmodule Socket.Endpoint do
  use Phoenix.Endpoint, otp_app: :block_poker

  # Основной канал связи с клиентом. Аутентификация соединения — в UserSocket.
  socket "/socket", Socket.UserSocket,
    websocket: [connect_info: [:peer_data, :x_headers]],
    longpoll: false

  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :block_poker
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.Head

  # HTTP-слой намеренно тощий: только то, что нельзя сделать по сокету.
  plug Api.Router
end
