defmodule BlockPoker.GameMode.Cash do
  @moduledoc """
  Кэш-игра: политика между раздачами.

  Фишки приходят бай-ином из кошелька и уходят cash-out'ом обратно — других
  способов их создать или уничтожить в комнате нет, и на этом стоит инвариант
  денег (§4 задачи 3). Проигранный стек означает предложение докупиться,
  а не вылет; встать можно в любой момент между раздачами.
  """

  @behaviour BlockPoker.GameMode

  alias BlockPoker.CashGames.CashGameSetting
  alias BlockPoker.Engine.HandSetup
  alias BlockPoker.Engine.Variant.Registry, as: VariantRegistry
  alias BlockPoker.Tables.{RoomState, Seat}
  alias BlockPoker.Wallet

  @impl true
  def hand_setup(%RoomState{} = state) do
    players = state |> RoomState.seats() |> Enum.filter(&Seat.in_game?/1)

    if length(players) < 2 do
      {:error, :not_enough_players}
    else
      {:ok, build_setup(state, players)}
    end
  end

  @impl true
  def on_hand_finished(%RoomState{} = state, _results) do
    %{state | hands_played: state.hands_played + 1, phase: :idle}
  end

  @impl true
  def on_zero_stack(%RoomState{} = state, %Seat{} = seat) do
    RoomState.zero_stack(state, seat.number)
  end

  @impl true
  # Критерий — участие в идущей раздаче, а не стек места: на олл-ине стек
  # равен нулю, и проверка по нему выпускала игрока из-за стола вместе
  # с его правом на банк.
  def can_leave?(%RoomState{} = state, %Seat{} = seat),
    do: not RoomState.in_hand?(state, seat.number)

  @impl true
  def take_buy_in(%RoomState{} = state, user_id, amount, reservation_id) do
    case Wallet.buy_in(user_id, state.setting.currency, amount, "buyin:#{reservation_id}",
           ref_id: state.room_id
         ) do
      {:ok, _entry} -> :ok
      {:error, reason} -> {:error, wallet_error(reason)}
    end
  end

  @impl true
  def return_chips(%RoomState{} = state, user_id, amount, ref) do
    case Wallet.cash_out(user_id, state.setting.currency, amount, "cashout:#{ref}",
           ref_id: state.room_id
         ) do
      {:ok, _entry} -> :ok
      {:error, reason} -> {:error, wallet_error(reason)}
    end
  end

  @doc """
  Рейк с банка. На `play_money` не берётся вовсе — ветвление живёт здесь,
  а не в настройке: поля рейка в шаблоне есть, но при игровых фишках
  игнорируются.
  """
  @impl true
  @spec rake(CashGameSetting.t(), pot :: non_neg_integer(), players :: pos_integer(), keyword()) ::
          non_neg_integer()
  def rake(setting, pot, players, opts \\ [])

  def rake(%CashGameSetting{currency: :play_money}, _pot, _players, _opts), do: 0

  def rake(%CashGameSetting{} = setting, pot, players, opts) do
    if setting.no_flop_no_drop and not Keyword.get(opts, :saw_flop?, true) do
      0
    else
      # `rake_percent` хранится в сотых долях процента: 500 = 5%.
      raw = div(pot * setting.rake_percent, 10_000)

      case CashGameSetting.rake_cap(setting, players) do
        nil -> raw
        cap -> min(raw, cap)
      end
    end
  end

  defp build_setup(state, players) do
    setting = state.setting

    %HandSetup{
      variant: VariantRegistry.fetch!(setting.game_type),
      players:
        Enum.map(players, fn seat ->
          %{
            seat: seat.number,
            id: seat.user_id,
            stack: seat.stack,
            post: seat.post,
            dead_post: seat.dead_post
          }
        end),
      button_seat: state.button_seat || hd(players).number,
      small_blind: setting.small_blind,
      big_blind: setting.big_blind,
      ante: setting.ante,
      ante_type: setting.ante_type
    }
  end

  defp wallet_error(:insufficient_funds), do: :insufficient_funds
  defp wallet_error(:not_found), do: :wallet_not_found
  defp wallet_error(_other), do: :internal_error
end
