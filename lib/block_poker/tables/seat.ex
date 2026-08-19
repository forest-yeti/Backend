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

  `role` — снимок роли учётки на момент посадки, рядом с ником и аватаром и
  по той же причине: стол не ходит в базу за правами на каждый снапшот. Роль
  сама по себе клиенту не отдаётся никогда — из неё считается лишь то, что
  игроку разрешено (§9 CLAUDE.md).

  `name` и `avatar` — снимок профиля на момент посадки: стол показывает игрока
  ником, а не UUID, и не ходит за этим в базу на каждый снапшот.

  `waiting_for_bb`, `missed_blinds` и `can_post` — вход в игру (§6 задачи 3).
  Само решение принимает `Engine.EntryRules`, здесь только его результат.

  `time_bank` — личный запас времени сверх обычного времени на ход
  (`Engine.TimeBank`), `preselect` — заранее выбранное действие
  (`Engine.Preselect`). Оба живут в месте по той же причине, что и `stats`:
  это состояние *игрока за этим столом*, а не раздачи, и оно обязано
  переживать смену улицы и раздачи, но не уход из-за стола.

  `stats` — показатели игрока за сессию. Они лежат **в месте**, а не в
  отдельной таблице комнаты, потому что правило сброса в кэше ровно такое:
  сессия заканчивается уходом с места. `Seat.free/1` отдаёт чистое место —
  и счётчики обнуляются сами, без отдельной уборки. В турнире правило другое
  (сессия — весь турнир, пересадка её не прерывает), и держателем там будет
  не место; `Engine.Stats` от этого выбора не зависит.
  """

  alias BlockPoker.Engine.{Preselect, Stats}

  @type role :: :default | :admin

  @type status :: :empty | :reserved | :playing | :sitting_out | :disconnected | :leaving

  @type t :: %__MODULE__{
          number: pos_integer(),
          user_id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          avatar: String.t() | nil,
          role: role(),
          status: status(),
          stack: non_neg_integer(),
          reservation_id: String.t() | nil,
          waiting_for_bb: boolean(),
          post_required: boolean(),
          can_post: boolean(),
          missed_blinds: non_neg_integer(),
          hands_sat_out: non_neg_integer(),
          wants_post: boolean(),
          post: non_neg_integer(),
          dead_post: non_neg_integer(),
          time_bank: non_neg_integer(),
          preselect: Preselect.t() | nil,
          chat_sent_at: [integer()],
          reacted_at: integer() | nil,
          stats: Stats.t()
        }

  @enforce_keys [:number]
  defstruct [
    :number,
    :user_id,
    :name,
    :avatar,
    :reservation_id,
    role: :default,
    status: :empty,
    stack: 0,
    waiting_for_bb: false,
    post_required: false,
    can_post: false,
    missed_blinds: 0,
    hands_sat_out: 0,
    # Игрок нажал «не ждать блайнда». Это **намерение**, а не решение:
    # во что оно обойдётся, зависит от положения кнопки, а она успевает
    # сдвинуться, поэтому считается оно в момент старта раздачи, а не нажатия.
    wants_post: false,
    # Взнос за вход в ближайшую раздачу: живая часть и мёртвая (`EntryRules`).
    # Одноразовые — раздача их забирает и обнуляет.
    post: 0,
    dead_post: 0,
    time_bank: 0,
    preselect: nil,
    # Отметки последних сообщений игрока: по ним считается частота (`Chat`).
    chat_sent_at: [],
    # Момент последней реакции (монотонные мс): по нему считается кулдаун
    # (`Reactions`). Одна отметка, а не список, — реакция разрешена одна.
    reacted_at: nil,
    stats: %Stats{}
  ]

  @spec new(pos_integer()) :: t()
  def new(number), do: %__MODULE__{number: number}

  @doc "Администратор ли сидящий — снимок роли, снятый при посадке."
  @spec admin?(t()) :: boolean()
  def admin?(%__MODULE__{role: :admin}), do: true
  def admin?(%__MODULE__{}), do: false

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
