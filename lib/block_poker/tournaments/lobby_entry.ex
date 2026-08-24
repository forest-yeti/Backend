defmodule BlockPoker.Tournaments.LobbyEntry do
  @moduledoc """
  Строка турнирной витрины: инстанс глазами лобби.

  Живёт в ядре, а не во view, потому что здесь считаются **доменные**
  величины: статус для фильтра, признаки турнира, цена входа. View решает,
  какие поля показать, но не вычисляет новых (§3 CLAUDE.md).

  Строка описывает **инстанс**, а не шаблон: «Вечерний фрибай» сегодня и
  завтра — два разных турнира с одинаковыми правилами, и регистрируется
  игрок в конкретный запуск.
  """

  alias BlockPoker.Tournaments
  alias BlockPoker.Tournaments.{Tournament, TournamentSetting}

  @typedoc """
  Статус витрины. От статуса инстанса отличается одним значением:
  `late_reg` — это `running` с ещё открытой поздней регистрацией.

  Отдельное значение существует потому, что игрок спрашивает не «идёт ли
  турнир», а «могу ли я войти прямо сейчас», и для него это разные
  состояния.
  """
  @type status :: :announced | :registering | :running | :late_reg | :finished

  @type t :: %{
          tournament_id: Ecto.UUID.t(),
          setting_id: Ecto.UUID.t(),
          status: status(),
          starts_at: DateTime.t(),
          entry_price: non_neg_integer(),
          kinds: [atom()],
          setting: TournamentSetting.t(),
          tournament: Tournament.t()
        }

  @doc "Собирает строку витрины из инстанса вместе с его шаблоном."
  @spec build(Tournament.t(), keyword()) :: t()
  def build(%Tournament{setting: %TournamentSetting{} = setting} = tournament, opts \\ []) do
    %{
      tournament_id: tournament.id,
      setting_id: setting.id,
      status: status(tournament, Keyword.get(opts, :now, DateTime.utc_now())),
      starts_at: tournament.starts_at,
      entry_price: TournamentSetting.entry_price(setting),
      kinds: TournamentSetting.kinds(setting),
      setting: setting,
      tournament: tournament,
      registered: Keyword.get(opts, :registered, false),
      has_ticket: Keyword.get(opts, :has_ticket, false)
    }
  end

  @doc """
  Статус для витрины.

  `late_reg` выводится, а не хранится: второе поле о том же моменте
  разошлось бы с первым на первом же рестарте. Считается по
  `late_reg_until`, который проставлен на старте.
  """
  @spec status(Tournament.t(), DateTime.t()) :: status()
  def status(%Tournament{status: :running} = tournament, now) do
    if late_reg_open?(tournament, now), do: :late_reg, else: :running
  end

  def status(%Tournament{status: :late_reg_closed}, _now), do: :running
  def status(%Tournament{status: :finishing}, _now), do: :running
  def status(%Tournament{status: status}, _now), do: status

  @doc "Открыт ли вход в идущий турнир прямо сейчас."
  @spec late_reg_open?(Tournament.t(), DateTime.t()) :: boolean()
  def late_reg_open?(%Tournament{late_reg_until: nil}, _now), do: false

  def late_reg_open?(%Tournament{late_reg_until: until}, now) do
    DateTime.compare(until, now) == :gt
  end

  @doc """
  Призовой фонд, каким игрок видит его **сейчас**.

  `tournament.prize_pool` заполняется только при закрытии поздней
  регистрации (`Tournaments.close_late_reg/1`): до того он ноль, и
  показывать его значило бы объявлять пустой фонд весь час, пока идёт
  запись. Живая величина — собранное со входов, но не ниже гарантии:
  тем же способом фонд потом и фиксируется, поэтому после фиксации
  цифра не дёргается.
  """
  @spec prize_pool(t()) :: non_neg_integer()
  def prize_pool(%{setting: setting, tournament: tournament}) do
    %{prize_pool: pool} =
      BlockPoker.Engine.TournamentPayout.pool(tournament.collected, setting.guarantee)

    max(tournament.prize_pool, pool)
  end

  @doc """
  Число оплачиваемых мест при текущей явке — то, что игрок видит как
  «до денег осталось N».

  Считается ядром (`Engine.TournamentPayout`), а не витриной: это
  доменная величина, зависящая от сетки и явки.
  """
  @spec paid_places(t()) :: non_neg_integer()
  def paid_places(%{setting: setting, tournament: tournament}) do
    BlockPoker.Engine.TournamentPayout.paid_places(
      Tournaments.payout_grid(setting),
      tournament.entries_count,
      tournament.players_count
    )
  end
end
