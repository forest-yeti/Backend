defmodule BlockPoker.Tournaments.Workers.ExpireTickets do
  @moduledoc """
  Гасит просроченные билеты. Заводится по расписанию раз в десять минут.

  Джоба не защищает регистрацию — та и без неё не пустит истёкший билет
  (`Tickets.find_for/3` фильтрует по сроку). Она нужна, чтобы игрок видел
  в кошельке правду, а не «активный» купон, которым нельзя
  воспользоваться: просроченный билет, выглядящий рабочим, — это жалоба
  в поддержку, а не косметика.

  Идемпотентна по построению: `UPDATE ... WHERE status = 'active' AND
  expires_at <= now`. Повторный прогон не находит ничего и ничего не
  портит, поэтому ретраи безопасны.
  """

  use Oban.Worker, queue: :tickets, max_attempts: 3

  alias BlockPoker.Tickets

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, count} = Tickets.expire_due()

    # Ноль в лог не пишем: джоба тикает каждые десять минут, и «ничего
    # не произошло» шестью строками в час затопило бы всё остальное.
    if count > 0, do: Logger.info("билетов просрочено: #{count}")

    :ok
  end
end
