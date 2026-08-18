defmodule BlockPoker.Repo do
  use Ecto.Repo,
    otp_app: :block_poker,
    adapter: Ecto.Adapters.MyXQL
end
