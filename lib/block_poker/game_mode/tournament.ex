defmodule BlockPoker.GameMode.Tournament do
  @moduledoc """
  Sit & Go: политика между раздачами.

  Отличие от кэша одно, и из него следует всё остальное: **фишка здесь —
  не деньги, а позиция в структуре мест.** Она не покупается и не
  продаётся, её нельзя унести со стола, и проигранный стек означает не
  убыток, а вылет. Поэтому:

    * бай-ин за столом не берётся — деньги ушли один раз, на регистрации,
      и стол их больше не касается;
    * cash-out не существует: `return_chips/4` — no-op, потому что
      возвращать в кошелёк турнирные фишки не во что;
    * рейка с банка нет: банк в фишках, брать с него процент нечего.
      Доход рума вшит в матожидание таблицы призов (`Engine.PrizePool`);
    * встать из-за стола нельзя. Ушедший продолжает платить вынужденные
      ставки и складывать карты, пока не вылетит: иначе структура мест
      разваливалась бы по желанию участника;
    * run it twice, страддл и бомб-пот выключены **всегда** и настройкой
      не управляются — каждый из них меняет либо распределение мест, либо
      цену круга, то есть правит турнирную структуру посреди турнира.

  Номиналы приходят из текущего уровня расписания (`Engine.BlindSchedule`),
  а не из полей шаблона: в турнире они растут.
  """

  @behaviour BlockPoker.GameMode

  alias BlockPoker.Engine.BlindSchedule
  alias BlockPoker.Engine.HandSetup
  alias BlockPoker.Engine.Variant.Registry, as: VariantRegistry
  alias BlockPoker.SitAndGo
  alias BlockPoker.SitAndGo.SitAndGoSetting
  alias BlockPoker.Tables.{RoomState, Seat}

  @doc """
  Заводит расписание уровней, скопировав его из шаблона.

  Копия, а не ссылка на строки БД: комната один раз берёт настройки себе
  и больше за ними не ходит — правка структуры в базе не должна поднимать
  блайнды посреди идущего турнира.
  """
  @impl true
  def init_room(%RoomState{setting: setting} = state) do
    RoomState.start_tournament(state, SitAndGo.blind_schedule(setting))
  end

  @impl true
  def prize_table(%RoomState{setting: setting}), do: SitAndGo.prize_table(setting)

  @impl true
  def hand_setup(%RoomState{} = state) do
    players = state |> RoomState.seats() |> Enum.filter(&playing?/1)

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

  @doc """
  Игрок остался без фишек — это вылет, а не предложение докупиться.

  Место считается от числа ещё не выбывших: в турнире на шестерых первый
  вылетевший занимает шестое. Игрок остаётся за столом зрителем, потому
  что освобождать место в Sit & Go не для кого — состав набран до старта
  и новых участников не будет.
  """
  @impl true
  def on_zero_stack(%RoomState{} = state, %Seat{} = seat) do
    state
    |> RoomState.eliminate(seat, place(state))
    |> RoomState.zero_stack(seat.number)
  end

  @doc """
  Встать из-за стола нельзя никогда.

  Это не строгость ради строгости: взнос уплачен за место в структуре,
  и уход с фишками означал бы, что оставшиеся играют за приз, часть
  которого унесли. Отключившийся игрок продолжает участвовать —
  вынужденные ставки съедают его стек, и он вылетает по правилам.
  """
  @impl true
  def can_leave?(%RoomState{}, %Seat{}), do: false

  @doc """
  Стек в турнире один и тот же для всех: стартовый и ровно он.

  Границ бай-ина здесь нет не потому, что они широкие, а потому, что
  выбора нет вовсе — разные стартовые стеки сделали бы структуру мест
  бессмысленной. Докупка по той же причине невозможна: ненулевой стек
  означает, что игрок уже в турнире.
  """
  @impl true
  def validate_buy_in(%RoomState{setting: setting}, amount, current_stack) do
    if current_stack == 0 and amount == setting.starting_stack do
      :ok
    else
      {:error, :invalid_buy_in}
    end
  end

  @impl true
  def entry_policy(%RoomState{} = state) do
    level = RoomState.current_level(state)

    %{
      # Входа посреди турнира не бывает, но большой блайнд текущего уровня
      # всё равно называется честно: по нему считаются номиналы, а не
      # право войти.
      big_blind: (level && level.big_blind) || 0,
      allow_post_blind?: false,
      dodge_window_hands: 0
    }
  end

  @impl true
  def bet_unit(%RoomState{} = state) do
    case RoomState.current_level(state) do
      nil -> 0
      level -> structure(state).bet_unit(BlindSchedule.limits(level))
    end
  end

  @doc """
  Sit & Go стартует сам, и другого способа его начать нет: он начинается
  тогда, когда собрался пул, — ждать больше нечего.
  """
  @impl true
  def auto_start?(%RoomState{}), do: true

  @impl true
  def sit_out_timeout_ms(%RoomState{}), do: nil

  @impl true
  def rebuy_prompt_ms(%RoomState{}), do: nil

  @impl true
  def run_it_twice?(%RoomState{}), do: false

  @impl true
  def straddle?(%RoomState{}), do: false

  @impl true
  def bomb_pot(%RoomState{}), do: nil

  @doc """
  Бай-ин за столом не берётся: деньги списаны на регистрации, а стартовый
  стек — это фишки, которые турнир выдаёт сам.
  """
  @impl true
  def take_buy_in(%RoomState{}, _user_id, _amount, _reservation_id), do: :ok

  @doc "Возвращать в кошелёк нечего: турнирная фишка деньгами не является."
  @impl true
  def return_chips(%RoomState{}, _user_id, _amount, _ref), do: :ok

  @doc "Рейка с банка в турнире нет и быть не может — банк в фишках."
  @impl true
  def rake(_setting, _pot, _players, _opts \\ []), do: 0

  defp structure(%RoomState{setting: setting}), do: SitAndGoSetting.structure(setting)

  # Играет тот, кто занимает место и ещё не вылетел. Нулевой стек — это
  # вылет, а не пауза: докупиться ему не предложат.
  defp playing?(%Seat{} = seat), do: Seat.in_game?(seat) and seat.stack > 0

  # Место вылетевшего — это число ещё не выбывших, считая его самого.
  defp place(%RoomState{setting: setting, tournament: tournament}) do
    setting.max_players - length(tournament.standings)
  end

  defp build_setup(%RoomState{} = state, players) do
    level = RoomState.current_level(state)

    %HandSetup{
      variant: VariantRegistry.fetch!(state.setting.game_type),
      players:
        Enum.map(players, fn seat ->
          # Взносов за вход в турнире не бывает: все начали одновременно
          # и заплатили одинаково.
          %{seat: seat.number, id: seat.user_id, stack: seat.stack, post: 0, dead_post: 0}
        end),
      button_seat: state.button_seat || hd(players).number,
      small_blind: level.small_blind,
      big_blind: level.big_blind,
      ante: level.ante,
      # Анте уровня платят все и каждую раздачу: очереди платить, от
      # которой можно уклониться, в турнире нет.
      ante_type: :per_player,
      bomb_pot: nil,
      run_it_twice_allowed: false
    }
  end
end
