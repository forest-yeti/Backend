defmodule BlockPoker.Tables.Seat do
  @moduledoc """
  Место за столом. Данные, без поведения комнаты: кто сидит, сколько у него
  фишек и в каком он состоянии.

  Состояния:

    * `:empty` — свободно;
    * `:reserved` — за игроком на время похода в кошелёк (§4 задачи 3);
    * `:playing` — участвует в раздачах;
    * `:sitting_out` — сидит, но раздачи пропускает (в т.ч. с нулевым стеком,
      пока думает над докупкой);
    * `:disconnected` — связь оборвалась, место держится grace-период;
    * `:leaving` — игрок встал, стек уже уехал в кошелёк, но подтверждения
      транзакции ещё нет. Место в этот момент занято: отдать его другому,
      пока фишки в полёте, нельзя.

  `name` и `avatar` — снимок профиля на момент посадки: стол показывает игрока
  ником, а не UUID, и не ходит за этим в базу на каждый снапшот.

  `waiting_for_bb`, `missed_blinds` и `can_post` — вход в игру (§6 задачи 3).
  Само решение принимает `Engine.EntryRules`, здесь только его результат.

  `stats` — показатели игрока за сессию. Они лежат **в месте**, а не в
  отдельной таблице комнаты, потому что правило сброса в кэше ровно такое:
  сессия заканчивается уходом с места. `Seat.free/1` отдаёт чистое место —
  и счётчики обнуляются сами, без отдельной уборки. В турнире правило другое
  (сессия — весь турнир, пересадка её не прерывает), и держателем там будет
  не место; `Engine.Stats` от этого выбора не зависит.
  """

  alias BlockPoker.Engine.Stats

  @type status :: :empty | :reserved | :playing | :sitting_out | :disconnected | :leaving

  @type t :: %__MODULE__{
          number: pos_integer(),
          user_id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          avatar: String.t() | nil,
          status: status(),
          stack: non_neg_integer(),
          reservation_id: String.t() | nil,
          waiting_for_bb: boolean(),
          post_required: boolean(),
          can_post: boolean(),
          missed_blinds: non_neg_integer(),
          hands_sat_out: non_neg_integer(),
          stats: Stats.t()
        }

  @enforce_keys [:number]
  defstruct [
    :number,
    :user_id,
    :name,
    :avatar,
    :reservation_id,
    status: :empty,
    stack: 0,
    waiting_for_bb: false,
    post_required: false,
    can_post: false,
    missed_blinds: 0,
    hands_sat_out: 0,
    stats: %Stats{}
  ]

  @spec new(pos_integer()) :: t()
  def new(number), do: %__MODULE__{number: number}

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{status: :empty}), do: true
  def empty?(%__MODULE__{}), do: false

  @doc "Занято ли место — резерв считается занятостью."
  @spec taken?(t()) :: boolean()
  def taken?(seat), do: not empty?(seat)

  @doc "Сидит ли за местом игрок с деньгами (резерв ещё не игрок)."
  @spec occupied?(t()) :: boolean()
  def occupied?(%__MODULE__{status: status}),
    do: status in [:playing, :sitting_out, :disconnected]

  @doc "Участвует ли место в ближайшей раздаче."
  @spec in_game?(t()) :: boolean()
  def in_game?(%__MODULE__{} = seat) do
    seat.status == :playing and not seat.waiting_for_bb and not seat.post_required and
      seat.stack > 0
  end

  @spec free(t()) :: t()
  def free(%__MODULE__{number: number}), do: new(number)
end
