defmodule BlockPoker.GameMode do
  @moduledoc """
  Шов между комнатой и раздачей (§9 задачи 3).

  Наблюдение, на котором держится разделение: **сама раздача везде одинакова,
  различия живут между раздачами.** Порядок хода, набор решений, min-raise,
  сайд-поты — один и тот же код для кэша и турнира. Различаются вещи вокруг:
  откуда фишки, что значит проигранный стек, можно ли встать, как берётся
  комиссия.

  Всё «вокруг» — за этим behaviour. `TableServer` зовёт `GameMode` там, где
  начинается политика, и `Engine.Rules` там, где идёт раздача.
  """

  alias BlockPoker.Engine.HandSetup
  alias BlockPoker.Tables.RoomState
  alias BlockPoker.Tables.Seat

  @doc "Собрать вход раздачи: кто играет, с какими стеками и блайндами."
  @callback hand_setup(RoomState.t()) :: {:ok, HandSetup.t()} | {:error, :not_enough_players}

  @doc "Раздача завершилась: раздать результаты, обновить состояние комнаты."
  @callback on_hand_finished(RoomState.t(), results :: term()) :: RoomState.t()

  @doc "Игрок остался без фишек: кэш предлагает докупиться, турнир — вылет."
  @callback on_zero_stack(RoomState.t(), Seat.t()) :: RoomState.t()

  @doc "Может ли игрок встать из-за стола прямо сейчас."
  @callback can_leave?(RoomState.t(), Seat.t()) :: boolean()

  @doc """
  Взять бай-ин. В кэше — списание из кошелька, в турнире фишки берутся
  из стартового стека, и денег это не касается вовсе.
  """
  @callback take_buy_in(RoomState.t(), Ecto.UUID.t(), pos_integer(), String.t()) ::
              :ok | {:error, atom()}

  @doc "Рейк с банка: в кэше по шаблону лимита, в турнире всегда 0."
  @callback rake(setting :: term(), pot :: non_neg_integer(), players :: pos_integer(), keyword()) ::
              non_neg_integer()

  @doc "Вернуть фишки игроку: в кэше — cash-out в кошелёк, в турнире — no-op."
  @callback return_chips(RoomState.t(), Ecto.UUID.t(), non_neg_integer(), String.t()) ::
              :ok | {:error, atom()}
end
