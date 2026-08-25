defmodule BlockPoker.GameMode.Mtt do
  @moduledoc """
  Политика стола внутри многостолового турнира.

  От `GameMode.Tournament` (Sit & Go) отличается одним, и из этого следует
  всё остальное: **стол здесь не самостоятелен.** В Sit & Go стол и есть
  турнир — он знает свой состав, свой приз и свой конец. В MTT стол это
  место, где идут раздачи, а турниром распоряжается `TournamentServer`:

    * **уровень приходит извне.** Стол не поднимает блайнды по своему
      таймеру и не решает, когда им смениться: он применяет тот уровень,
      который назвал турнир, и делает это между раздачами;
    * **вылет не окончателен.** Игрок без фишек освобождает место, но
      место в результатах ему присваивает турнир — пока уровень разрешает
      ре-энтри, вылета могло и не быть;
    * **конца у стола нет.** Он не «заканчивается победителем»: его либо
      схлопывают, либо он становится финальным. Поэтому `finished?/1`
      всегда `false`, а расчёт делает турнир;
    * **место освобождается.** В Sit & Go вылетевший остаётся зрителем —
      сажать на его место некого. Здесь наоборот: место нужно для поздней
      регистрации, ре-энтри и пересадок, и держать за вылетевшим нечего.

  ## Что унаследовано без изменений

  Фишка — не деньги, а позиция в структуре мест. Отсюда: бай-ин за столом
  не берётся (деньги ушли на регистрации), cash-out не существует, рейка
  с банка нет.

  **Run it twice, страддл и бомб-пот выключены всегда** и настройкой не
  управляются. Страддл и бомб-пот меняют цену круга посреди уровня, run it
  twice меняет распределение мест — а в турнире место это и приз, и голова.
  Игрок не может согласием изменить структуру турнира, в который вошли все
  остальные.

  ## Sit-out разрешён и означает автофолд

  Место остаётся за игроком, вынужденные ставки платятся, карты
  складываются. Отойти от компьютера можно и не нажимая кнопку — просто
  не отвечая; запрет кнопки не удержал бы игрока за столом, а только
  лишил бы его возможности честно сообщить об этом остальным.
  """

  @behaviour BlockPoker.GameMode

  alias BlockPoker.Engine.BlindSchedule
  alias BlockPoker.Engine.HandSetup
  alias BlockPoker.Engine.Variant.Registry, as: VariantRegistry
  alias BlockPoker.Tables.{RoomState, Seat}
  alias BlockPoker.Tournaments.TableSetting

  @doc """
  Заводит расписание уровней из настроек стола.

  Копия, а не ссылка: настройки пришли из снапшота инстанса, и стол
  больше никуда за ними не ходит.
  """
  @impl true
  def init_room(%RoomState{setting: setting} = state) do
    RoomState.start_tournament(state, setting.levels)
  end

  @doc """
  Призового фонда у **стола** нет: он принадлежит турниру и делится по
  сетке выплат, а не разыгрывается за этим столом.
  """
  @impl true
  def game_mode_id, do: :mtt

  @impl true
  def prize_table(%RoomState{}), do: nil

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
  Игрок без фишек: место освобождается, но **результата ему стол не
  присваивает**.

  Место в турнирной таблице считает `TournamentServer` — он один знает,
  сколько живых осталось за всеми столами, и он же решает, окончателен ли
  вылет: пока уровень разрешает ре-энтри, игроку предложат войти заново,
  и тогда вылета не было вовсе.

  Стол в этот момент делает единственное, что в его власти: убирает
  игрока со стола, чтобы место можно было отдать.
  """
  @impl true
  def on_zero_stack(%RoomState{} = state, %Seat{} = seat) do
    RoomState.zero_stack(state, seat.number)
  end

  @doc """
  Встать из-за стола нельзя.

  Уход означал бы, что оставшиеся играют за приз, часть которого унесли.
  Пересадка при этом столом не считается: её делает турнир, снимая игрока
  напрямую.
  """
  @impl true
  def can_leave?(%RoomState{}, %Seat{}), do: false

  @doc """
  Стол турнира не заканчивается сам.

  Его либо схлопывают, либо он становится финальным; расчёт делает
  турнир, потому что победитель определяется по всем столам сразу.
  """
  @impl true
  def finished?(%RoomState{}), do: false

  @doc "Результаты считает турнир: стол видит только своих игроков."
  @impl true
  def results(%RoomState{}), do: []

  @doc """
  Стек за столом не докупается: фишки приходят от турнира — стартовые
  при посадке, добавочные при аддоне, — и стол их не выдаёт.
  """
  @impl true
  def max_add_chips(%RoomState{}, _current_stack), do: 0

  @doc """
  Посадить можно только с тем стеком, который назвал турнир.

  Проверка нестрогая по величине намеренно: стек зависит от того, чем
  игрок вошёл (стартовый вход, ре-энтри, поздняя регистрация после
  аддона), и знает об этом турнир, а не стол. Стол проверяет лишь, что
  место свободно.
  """
  @impl true
  def validate_buy_in(%RoomState{}, amount, current_stack) do
    if current_stack == 0 and amount > 0, do: :ok, else: {:error, :invalid_buy_in}
  end

  @doc """
  Входа за взнос в турнире не бывает: посреди уровня никто не «садится
  в круг» — сажает турнир, и он же решает, ждать ли большого блайнда.
  """
  @impl true
  def entry_policy(%RoomState{} = state) do
    level = RoomState.current_level(state)

    %{
      big_blind: (level && level.big_blind) || 0,
      allow_post_blind?: false,
      dodge_window_hands: 0,
      # Севший играет ближайшую раздачу: место дал турнир, а не игрок его
      # выбрал. Ждать большого блайнда после поздней регистрации,
      # ре-энтри или пересадки значило бы сидеть без карт целый круг.
      immediate_entry?: true
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
  Стол турнира стартует сам, как только за ним двое.

  Ждать нечего: состав назначил турнир, и «ручной старт» здесь означал бы,
  что один стол задерживает всех остальных.
  """
  @impl true
  def auto_start?(%RoomState{}), do: true

  @impl true
  def limits(%RoomState{} = state) do
    case RoomState.current_level(state) do
      nil -> %{small_blind: 0, big_blind: 0, ante: 0}
      level -> %{small_blind: level.small_blind, big_blind: level.big_blind, ante: level.ante}
    end
  end

  @doc """
  Тайминги стола. Докупки здесь нет, поэтому её ключа нет вовсе — вместо
  нуля, по которому клиент нарисовал бы счётчик несуществующей механики.

  `rebuy_prompt_ms` при этом есть: окно ре-энтри существует, но открывает
  его турнир, а не стол.
  """
  @impl true
  def timings(%RoomState{setting: setting}) do
    %{
      action_timeout_ms: setting.action_timeout_ms,
      time_bank_ms: setting.time_bank_ms,
      time_bank_refill: setting.time_bank_refill,
      disconnect_grace_ms: setting.disconnect_grace_ms
    }
  end

  @impl true
  def betting_structure(%RoomState{} = state), do: structure(state)

  @impl true
  def display_name(%RoomState{setting: setting}), do: setting.name

  @doc """
  Двое — и раздача идёт.

  В Sit & Go порог равен полному составу, потому что там пул обязан
  собраться. Здесь состав уже собран турниром, а за конкретным столом
  в любой момент может остаться и двое: хедз-ап на финалке — обычное
  состояние, а не вырожденное.
  """
  @impl true
  def start_threshold(%RoomState{}), do: 2

  @doc """
  Автоматического выселения за паузу нет.

  Место в турнире продано, и освободить его за бездействие нельзя:
  просидевший паузу платит вынужденные ставки и вылетает по правилам
  игры, а не по таймеру комнаты.
  """
  @impl true
  def sit_out_timeout_ms(%RoomState{}), do: nil

  @doc """
  Окном ре-энтри распоряжается турнир: он один знает уровень, лимит
  игрока и число входов. Стол его не открывает.
  """
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
  Сесть за турнирный стол общим входом нельзя — вообще никому.

  Через `Tables.join_seat/5` в комнату приходит игрок, который **покупает**
  место: комната резервирует кресло, режим берёт деньги, комната сажает.
  В MTT покупать нечего — место продано регистрацией, стек назначает
  турнир, и садит он же, обращаясь к `TableServer` напрямую. Разрешить
  здесь `:ok` значит впустить за идущий турнир постороннего с фишками,
  которых никто не покупал: денег с него режим не берёт (их берут на
  регистрации), а размер стека в турнире не ограничен сверху ничем.

  Отказ живёт именно тут, а не в канале: право сесть — правило режима,
  а транспорт про режимы ничего не знает (§3 CLAUDE.md).
  """
  @impl true
  def take_buy_in(%RoomState{}, _user_id, _amount, _reservation_id),
    do: {:error, :not_registered}

  @doc "Возвращать в кошелёк турнирные фишки не во что."
  @impl true
  def return_chips(%RoomState{}, _user_id, _amount, _ref), do: :ok

  @doc "Рейка с банка в турнире нет и быть не может — банк в фишках."
  @impl true
  def rake(_setting, _pot, _players, _opts \\ []), do: 0

  defp structure(%RoomState{setting: %TableSetting{game_type: game_type}}) do
    game_type |> VariantRegistry.fetch!() |> then(& &1.betting_structure())
  end

  # Играет тот, кто занимает место и ещё не вылетел. Нулевой стек — это
  # вылет: докупиться ему не предложат.
  defp playing?(%Seat{} = seat), do: Seat.in_game?(seat) and seat.stack > 0

  defp build_setup(%RoomState{} = state, players) do
    level = RoomState.current_level(state)

    %HandSetup{
      variant: VariantRegistry.fetch!(state.setting.game_type),
      players:
        Enum.map(players, fn seat ->
          %{seat: seat.number, id: seat.user_id, stack: seat.stack, post: 0, dead_post: 0}
        end),
      button_seat: state.button_seat || hd(players).number,
      small_blind: level.small_blind,
      big_blind: level.big_blind,
      ante: level.ante,
      # Анте классическое, с каждого игрока: BB-анте в турнирах рума не
      # используется (см. `Tournaments.BlindLevel`).
      ante_type: :per_player,
      bomb_pot: nil,
      run_it_twice_allowed: false
    }
  end
end
