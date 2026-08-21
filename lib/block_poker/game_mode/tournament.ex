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
  alias BlockPoker.Engine.PrizePool
  alias BlockPoker.Engine.Variant.Registry, as: VariantRegistry
  alias BlockPoker.SitAndGo
  alias BlockPoker.SitAndGo.SitAndGoSetting
  alias BlockPoker.Tables.{RoomState, Seat}
  alias BlockPoker.Wallet

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
  Уйти можно только до старта — это отмена регистрации, а не выход из-за
  стола.

  После первой карты встать нельзя, и это не строгость ради строгости:
  взнос уплачен за место в структуре, и уход означал бы, что оставшиеся
  играют за приз, часть которого унесли. Отключившийся продолжает
  участвовать — вынужденные ставки съедают его стек, и он вылетает
  по правилам.
  """
  @impl true
  def can_leave?(%RoomState{game_started?: started?}, %Seat{}), do: not started?

  @doc """
  Требует ли турнир расчёта: живой остался один, а призы ещё не выплачены.

  Живых считаем по стекам, а не по занятым местам: вылетевшие остаются за
  столом зрителями, и «мест занято» до самого конца равно размеру пула.

  Флаг расчёта входит в условие намеренно. «Остался один» — состояние,
  а не событие: без него проверка срабатывала бы снова и снова, выплачивая
  приз повторно.
  """
  @impl true
  def finished?(%RoomState{tournament: nil}), do: false

  def finished?(%RoomState{game_started?: false}), do: false

  def finished?(%RoomState{tournament: %{settled?: true}}), do: false

  def finished?(%RoomState{} = state), do: RoomState.alive_count(state) <= 1

  @doc """
  Итоговая таблица: вылетевшие в порядке вылета плюс победитель первым.

  Победитель дописывается здесь, а не фиксируется по ходу игры: пока
  живых больше одного, победителя не существует, и запоминать его
  «заранее» было бы записью несуществующего факта.
  """
  @impl true
  def results(%RoomState{tournament: nil}), do: []

  def results(%RoomState{tournament: tournament} = state) do
    prize = tournament.prize
    shares = payout_shares(prize)

    # Победитель добавляется, только когда живой действительно один.
    # Пока их больше, «первый со стеком» — не победитель, а просто первый
    # в обходе мест, и назвать его первым местом значит соврать.
    entries =
      case RoomState.alive_count(state) do
        1 ->
          winner = Enum.find(RoomState.players(state), &(&1.stack > 0))

          [%{seat: winner.number, user_id: winner.user_id, place: 1} | tournament.standings]

        _more ->
          tournament.standings
      end

    entries
    |> Enum.sort_by(& &1.place)
    |> Enum.map(fn entry ->
      Map.put(entry, :amount, Enum.at(shares, entry.place - 1, 0))
    end)
  end

  defp payout_shares(nil), do: []

  defp payout_shares(%{pool: pool, payouts: payouts}), do: PrizePool.split(pool, payouts)

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

  @doc "Номиналы турнира — это текущий уровень структуры, а не поля шаблона."
  @impl true
  def limits(%RoomState{} = state) do
    case RoomState.current_level(state) do
      nil -> %{small_blind: 0, big_blind: 0, ante: 0}
      level -> %{small_blind: level.small_blind, big_blind: level.big_blind, ante: level.ante}
    end
  end

  @doc """
  Тайминги турнира. Докупки и тайм-аута паузы здесь нет вовсе, поэтому
  этих ключей в карте нет — вместо нулей, по которым клиент нарисовал бы
  счётчик несуществующей механики.
  """
  @impl true
  def timings(%RoomState{setting: setting}) do
    %{
      action_timeout_ms: setting.action_timeout_ms,
      time_bank_ms: setting.time_bank_ms,
      time_bank_refill: setting.time_bank_refill,
      disconnect_grace_ms: setting.disconnect_grace_ms,
      prize_reveal_ms: setting.prize_reveal_ms
    }
  end

  @impl true
  def betting_structure(%RoomState{} = state), do: structure(state)

  @impl true
  def display_name(%RoomState{setting: setting}), do: setting.name

  @doc """
  Турнир начинается только полным составом.

  Это то же самое требование, что и «пул обязан собраться»: 3-max
  стартует тройкой, 6-max шестёркой. Начать вчетвером за столом на шесть
  нельзя — призовой фонд и структура мест посчитаны от числа участников,
  и играть их меньшим составом значит раздать не то, за что заплатили.
  """
  @impl true
  def start_threshold(%RoomState{setting: setting}), do: setting.max_players

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

  @impl true
  def bomb_pot_view(%RoomState{}), do: nil

  @doc """
  Посадка за турнирный стол **и есть** регистрация: с кошелька списывается
  взнос шаблона, а не сумма фишек.

  Взнос и стек здесь — разные величины и разные шкалы: игрок платит
  деньгами, а получает турнирные фишки, которые деньгами не являются.
  Поэтому `amount` (стек) в списании не участвует вовсе.
  """
  @impl true
  def take_buy_in(%RoomState{} = state, user_id, _amount, reservation_id) do
    case Wallet.buy_in(
           user_id,
           state.setting.currency,
           state.setting.buy_in,
           "sng_buyin:#{reservation_id}",
           ref_id: state.room_id
         ) do
      {:ok, _entry} -> :ok
      {:error, reason} -> {:error, wallet_error(reason)}
    end
  end

  @doc """
  Отмена регистрации до старта возвращает **взнос**, а не стек.

  После старта возвращать нечего: фишки в игре, а причитающееся за место
  придёт выплатой приза. Развилка идёт по `game_started?`, потому что
  ровно он отделяет «ещё не начали» от «уже играем».
  """
  @impl true
  def return_chips(%RoomState{game_started?: true}, _user_id, _amount, _ref), do: :ok

  def return_chips(%RoomState{} = state, user_id, _amount, ref) do
    case Wallet.cash_out(
           user_id,
           state.setting.currency,
           state.setting.buy_in,
           "sng_refund:#{ref}",
           ref_id: state.room_id
         ) do
      {:ok, _entry} -> :ok
      {:error, reason} -> {:error, wallet_error(reason)}
    end
  end

  defp wallet_error(:insufficient_funds), do: :insufficient_funds
  defp wallet_error(:not_found), do: :wallet_not_found
  defp wallet_error(_other), do: :internal_error

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
