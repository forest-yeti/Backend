defmodule BlockPoker.GameMode.OfcCash do
  @moduledoc """
  Кэш-стол китайского покера: политика между раздачами.

  По движению денег это обычный кэш — фишки приходят бай-ином из кошелька и
  уходят cash-out'ом обратно, проигранный стек означает предложение
  докупиться, а не вылет. Отдельный режим нужен не поэтому, а потому что
  шаблон другой: у `OfcSetting` нет блайндов, анте, рейка, бомб-пота и
  взноса за вход, и `GameMode.Cash` читать её поля не может.

  Единственная механика, которой здесь нет в кэше вообще: **фантазия**.
  Она живёт в месте (`Seat`), а не в раздаче, поэтому переносить её из
  итогов раздачи в места обязан режим — тот, кто и отвечает за то, что
  происходит между раздачами. Стол об этом не знает ничего.
  """

  @behaviour BlockPoker.GameMode

  # Метка фантазии в непрозрачном поле места. Знает о ней только режим.
  @fantasy :fantasy

  alias BlockPoker.Engine.HandSetup
  alias BlockPoker.OfcGames.OfcSetting
  alias BlockPoker.Tables.{RoomState, Seat}
  alias BlockPoker.Wallet

  @impl true
  def hand_setup(%RoomState{} = state) do
    players = state |> RoomState.seats() |> Enum.filter(&Seat.in_game?/1)

    if length(players) < state.discipline.min_players() do
      {:error, :not_enough_players}
    else
      {:ok, build_setup(state, players)}
    end
  end

  @doc """
  Итоги раздачи: фантазия переезжает из раздачи в места.

  Дисциплина сказала, кто её заработал и удержал; хранит место, потому что
  фантазия по определению живёт **между** раздачами. Комната при этом не
  знает, что именно она хранит: ей уходит непрозрачное «что унести», и это
  единственное место в коде, где известно, что там лежит фантазия.

  Игрок, вставший из-за стола, теряет её вместе с местом — отдельного кода
  для этого не нужно, `Seat.new/1` заводит место пустым.
  """
  @impl true
  def on_hand_finished(%RoomState{} = state, results) do
    carry =
      results
      |> Kernel.||(%{})
      |> Map.get(:fantasy, %{})
      |> Map.new(fn {seat, earned?} -> {seat, if(earned? == true, do: @fantasy)} end)

    state = RoomState.put_carry(state, carry)

    %{state | hands_played: state.hands_played + 1, phase: :idle}
  end

  @impl true
  def on_zero_stack(%RoomState{} = state, %Seat{} = seat) do
    RoomState.zero_stack(state, seat.number)
  end

  @impl true
  def can_leave?(%RoomState{} = state, %Seat{} = seat),
    do: not RoomState.in_hand?(state, seat.number)

  @impl true
  def init_room(%RoomState{} = state), do: state

  @impl true
  def prize_table(%RoomState{}), do: nil

  @impl true
  def validate_buy_in(%RoomState{setting: setting}, amount, current_stack) do
    min = OfcSetting.min_buy_in_chips(setting)
    max = OfcSetting.max_buy_in_chips(setting)

    cond do
      not (is_integer(amount) and amount > 0) -> {:error, :invalid_buy_in}
      current_stack + amount < min -> {:error, :invalid_buy_in}
      max != nil and current_stack + amount > max -> {:error, :invalid_buy_in}
      true -> :ok
    end
  end

  @doc """
  Ждать круга не за чем: блайндов в дисциплине нет, а значит нет и способа
  от них уклониться. Севший играет с ближайшей раздачи.
  """
  @impl true
  def entry_policy(%RoomState{}) do
    %{big_blind: 0, allow_post_blind?: false, dodge_window_hands: 0}
  end

  @doc "Базовая единица стола — стоимость очка: от неё считаются бай-ин и лимит."
  @impl true
  def bet_unit(%RoomState{setting: setting}), do: OfcSetting.bet_unit(setting)

  @impl true
  def auto_start?(%RoomState{setting: setting}), do: setting.auto_start != false

  @doc """
  Номиналы стола. Блайндов у дисциплины нет, и подставлять сюда нули вместо
  них — не потеря: клиент читает `bet_unit`, а он приходит посчитанным.
  """
  @impl true
  def limits(%RoomState{setting: setting}) do
    %{small_blind: 0, big_blind: 0, ante: 0, point_value: setting.point_value}
  end

  @impl true
  def timings(%RoomState{setting: setting}) do
    %{
      action_timeout_ms: setting.action_timeout_ms,
      time_bank_ms: setting.time_bank_ms,
      time_bank_refill: setting.time_bank_refill,
      disconnect_grace_ms: setting.disconnect_grace_ms,
      rebuy_prompt_ms: setting.rebuy_prompt_ms,
      sit_out_timeout_ms: setting.sit_out_timeout_ms
    }
  end

  @doc """
  Вынужденных ставок нет: круг оплачивать нечем. Структура отвечает нулями
  по тем же соображениям, что и `limits/1`.
  """
  @impl true
  def betting_structure(%RoomState{}), do: BlockPoker.Engine.BettingStructure.Blinds

  @impl true
  def display_name(%RoomState{setting: setting}), do: name(setting)

  @doc "Подпись стола в лобби: цена очка и вместимость."
  @spec name(OfcSetting.t()) :: String.t()
  def name(%OfcSetting{name: name}) when is_binary(name) and name != "", do: name
  def name(%OfcSetting{} = setting), do: "OFC #{setting.point_value} #{setting.max_players}-max"

  @impl true
  def start_threshold(%RoomState{} = state), do: state.discipline.min_players()

  @impl true
  def sit_out_timeout_ms(%RoomState{setting: setting}), do: setting.sit_out_timeout_ms

  @impl true
  def rebuy_prompt_ms(%RoomState{setting: setting}), do: setting.rebuy_prompt_ms

  @doc "Двух прогонов, страддла и бомб-пота в дисциплине без банка не существует."
  @impl true
  def run_it_twice?(%RoomState{}), do: false

  @impl true
  def straddle?(%RoomState{}), do: false

  @impl true
  def bomb_pot(%RoomState{}), do: nil

  @impl true
  def bomb_pot_view(%RoomState{}), do: nil

  @impl true
  def finished?(%RoomState{}), do: false

  @impl true
  def results(%RoomState{}), do: []

  @impl true
  def max_add_chips(%RoomState{setting: setting}, current_stack) do
    case OfcSetting.max_buy_in_chips(setting) do
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
  Банка нет — процент брать не с чего, и рейк равен нулю по коду, а не по
  настройке. Рейк с очков — отдельное продуктовое решение, и до него в
  шаблоне не заведено ни одного поля, чтобы его нельзя было включить молча.
  """
  @impl true
  def rake(_setting, _pot, _players, _opts \\ []), do: 0

  defp build_setup(state, players) do
    %HandSetup{
      variant: OfcSetting.variant(state.setting),
      players:
        Enum.map(players, fn seat ->
          %{
            seat: seat.number,
            id: seat.user_id,
            stack: seat.stack,
            post: 0,
            dead_post: 0,
            fantasy: seat.carry == @fantasy
          }
        end),
      button_seat: state.button_seat || hd(players).number,
      point_value: state.setting.point_value
    }
  end

  defp wallet_error(:insufficient_funds), do: :insufficient_funds
  defp wallet_error(:not_found), do: :wallet_not_found
  defp wallet_error(_other), do: :internal_error
end
