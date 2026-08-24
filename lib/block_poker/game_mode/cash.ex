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

  @doc "Кэшу заводить нечего: комната из шаблона уже готова к игре."
  @impl true
  def init_room(%RoomState{} = state), do: state

  @doc "Призового фонда в кэше нет: игрок забирает выигранное со стола."
  @impl true
  def game_mode_id, do: :cash

  @impl true
  def prize_table(%RoomState{}), do: nil

  @doc """
  Границы бай-ина шаблона.

  Проверяется итоговый стек, а не сумма докупки: иначе проигравший почти
  всё оставался бы с парой фишек — формально не с нулём — и докупал один
  большой блайнд, садясь играть на 1.5bb за столом с минимумом в 40bb.
  """
  @impl true
  def validate_buy_in(%RoomState{setting: setting}, amount, current_stack) do
    min = CashGameSetting.min_buy_in_chips(setting)
    max = CashGameSetting.max_buy_in_chips(setting)

    cond do
      not (is_integer(amount) and amount > 0) -> {:error, :invalid_buy_in}
      current_stack + amount < min -> {:error, :invalid_buy_in}
      max != nil and current_stack + amount > max -> {:error, :invalid_buy_in}
      true -> :ok
    end
  end

  @impl true
  def entry_policy(%RoomState{setting: setting}) do
    %{
      big_blind: setting.big_blind,
      allow_post_blind?: setting.allow_post_blind,
      dodge_window_hands: setting.blind_dodge_window_hands,
      immediate_entry?: false
    }
  end

  @impl true
  def bet_unit(%RoomState{setting: setting}), do: CashGameSetting.bet_unit(setting)

  @impl true
  def auto_start?(%RoomState{setting: setting}), do: setting.auto_start != false

  @doc "Двое — минимум, при котором покер возможен; дальше стол играет любым составом."
  @impl true
  def limits(%RoomState{setting: setting}) do
    %{small_blind: setting.small_blind, big_blind: setting.big_blind, ante: setting.ante}
  end

  @impl true
  def timings(%RoomState{setting: setting}) do
    %{
      action_timeout_ms: setting.action_timeout_ms,
      time_bank_ms: setting.time_bank_ms,
      time_bank_refill: setting.time_bank_refill,
      disconnect_grace_ms: setting.disconnect_grace_ms,
      rebuy_prompt_ms: setting.rebuy_prompt_ms,
      straddle_offer_ms: BlockPoker.Tables.straddle_offer_ms(),
      sit_out_timeout_ms: setting.sit_out_timeout_ms
    }
  end

  @impl true
  def betting_structure(%RoomState{setting: setting}), do: CashGameSetting.structure(setting)

  @impl true
  def display_name(%RoomState{setting: setting}), do: CashGameSetting.display_name(setting)

  @impl true
  def start_threshold(%RoomState{}), do: 2

  @impl true
  def sit_out_timeout_ms(%RoomState{setting: setting}), do: setting.sit_out_timeout_ms

  @impl true
  def rebuy_prompt_ms(%RoomState{setting: setting}), do: setting.rebuy_prompt_ms

  @impl true
  def run_it_twice?(%RoomState{setting: setting}), do: setting.allowed_run_it_twice

  @impl true
  def straddle?(%RoomState{}), do: true

  @impl true
  def bomb_pot(%RoomState{setting: setting}), do: CashGameSetting.bomb_pot(setting)

  @impl true
  def bomb_pot_view(%RoomState{setting: setting}), do: CashGameSetting.bomb_pot(setting)

  @doc "Кэш-стол не заканчивается: он пустеет и ждёт новых игроков."
  @impl true
  def finished?(%RoomState{}), do: false

  @doc "Мест и призов в кэше нет: игрок забирает выигранное со стола cash-out'ом."
  @impl true
  def results(%RoomState{}), do: []

  @impl true
  def max_add_chips(%RoomState{setting: setting}, current_stack) do
    case CashGameSetting.max_buy_in_chips(setting) do
      nil -> nil
      max -> max(max - current_stack, 0)
    end
  end

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
    bomb_pot = state.bomb_pot

    %HandSetup{
      variant: VariantRegistry.fetch!(setting.game_type),
      players:
        Enum.map(players, fn seat ->
          %{
            seat: seat.number,
            id: seat.user_id,
            stack: seat.stack,
            # Взносы за вход в бомб-поте не берутся: платить блайндовую цену
            # круга не за что — блайндов в этой раздаче нет, а взнос бомб-пота
            # игрок платит наравне со всеми и он же оказывается ценой входа.
            # Право «войти сейчас» при этом гасится, как обычным взносом:
            # круг игрок отыграл полностью.
            post: entry_amount(seat.post, bomb_pot),
            dead_post: entry_amount(seat.dead_post, bomb_pot)
          }
        end),
      bomb_pot: bomb_pot,
      button_seat: state.button_seat || hd(players).number,
      run_it_twice_allowed: run_it_twice?(state),
      small_blind: setting.small_blind,
      big_blind: setting.big_blind,
      ante: setting.ante,
      ante_type: setting.ante_type
    }
  end

  defp entry_amount(_amount, %{} = _bomb_pot), do: 0
  defp entry_amount(amount, nil), do: amount

  defp wallet_error(:insufficient_funds), do: :insufficient_funds
  defp wallet_error(:not_found), do: :wallet_not_found
  defp wallet_error(_other), do: :internal_error
end
