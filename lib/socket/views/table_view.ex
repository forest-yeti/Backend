defmodule Socket.Views.TableView do
  @moduledoc """
  Единственное место, где состояние комнаты превращается в то, что видит
  конкретный игрок (§7 CLAUDE.md).

  Приватная информация вырезается **здесь и нигде больше**. В этой задаче
  раздач ещё нет, поэтому скрывать пока нечего, кроме чужих `reservation_id`;
  но точка фильтрации существует с первого дня, чтобы карманным картам
  из задачи 4 было куда прийти — и чтобы тест приватности проверял её,
  а не появившуюся позже заплатку.

  View может решать, какие поля показать, но не вычислять новые доменные
  значения: любая арифметика над фишками — признак утёкшей сюда логики.
  """

  alias BlockPoker.Engine.Card
  alias BlockPoker.Engine.HandInsight
  alias BlockPoker.Engine.Stats
  alias BlockPoker.Engine.Straddle
  alias BlockPoker.Tables.{RoomState, Seat}
  alias Socket.Views.LobbyView

  @doc "Полный персональный снапшот — после join и после реконнекта."
  @spec render(RoomState.t(), Ecto.UUID.t()) :: map()
  def render(%RoomState{} = room, user_id) do
    limits = room.mode.limits(room)

    %{
      room_id: room.room_id,
      setting_id: room.setting.id,
      name: room.mode.display_name(room),
      game_type: room.setting.game_type,
      # Дисциплина комнаты. Клиент выбирает по ней игровой экран: у
      # китайского покера нет ни борда, ни банка, и настроить под него
      # экран холдема нечем. Спрашивается у самой дисциплины — выводить её
      # из названия комнаты или числа мест значило бы гадать.
      discipline: room.discipline.id(),
      betting_structure: room.mode.betting_structure(room).id(),
      # Номиналы спрашиваются у режима: в кэше это поля шаблона, в турнире —
      # текущий уровень структуры. Выбирать между ними здесь значило бы
      # ветвиться по правилам игры (§3 CLAUDE.md).
      small_blind: limits.small_blind,
      big_blind: limits.big_blind,
      ante: limits.ante,
      # Номинал, от которого клиент считает шаги ползунка ставки. Приходит
      # посчитанным: выбирать между блайндом и анте — это ветвление по
      # правилам игры, которого в транспорте быть не может (§3 CLAUDE.md).
      bet_unit: RoomState.bet_unit(room),
      # Страддл: разрешён ли он за этим столом и с какой суммы начинается.
      # Минимум приходит посчитанным — «два номинала» это доменное правило,
      # и удваивать блайнд на клиенте значило бы завести его копию (§3).
      straddle_allowed: room.straddle_allowed?,
      straddle_min: Straddle.min_amount(RoomState.bet_unit(room)),
      # Идущее окно объявления суммы: остаток на момент отправки снапшота.
      straddle_ms: remaining(room.straddle_deadline_at),
      # Бомб-пот: правила стола (шанс и взнос) и решение по ближайшей
      # раздаче. Второе — не то же самое, что первое: шанс постоянен,
      # а `bomb_pot_next` появляется только когда кубик уже выпал.
      bomb_pot: room.mode.bomb_pot_view(room),
      bomb_pot_next: room.bomb_pot,
      max_players: room.setting.max_players,
      timings: room.mode.timings(room),
      action_seq: room.action_seq,
      phase: room.phase,
      button_seat: room.button_seat,
      hands_played: room.hands_played,
      visuals: LobbyView.visuals(room.setting),
      seats: room |> RoomState.seats() |> Enum.map(&seat(&1, user_id)),
      button_draw: button_draw(room),
      hand: hand(room),
      showdown: room.showdown,
      # Добровольно открытые карты прошедшей раздачи. Приходят и снапшотом,
      # а не только событием: подключившийся в паузу должен их увидеть.
      revealed: RoomState.revealed(room, System.monotonic_time(:millisecond)),
      # Открытый вопрос про два прогона с остатком времени: вернувшийся
      # внутри окна игрок должен успеть ответить.
      run_it_twice: RoomState.run_it_twice_view(room, System.monotonic_time(:millisecond)),
      # Турнирный блок либо `nil` — режим Sit & Go описывает себя здесь
      # целиком: уровень, время до повышения, приз и занятые места.
      tournament: tournament(room),
      chat: room.chat,
      # Панель реакций рисуется ровно этим списком и в этом порядке.
      reactions: BlockPoker.Tables.reactions(),
      you: you(room, user_id)
    }
  end

  @doc """
  Турнирная часть снапшота: то, чего нет за кэш-столом.

  `nil` за кэш-столом — это не «пустой турнир», а «режим другой», и клиент
  ветвится по наличию блока, а не по полям внутри него.

  Время до повышения считается здесь, потому что дедлайн хранится в
  монотонных миллисекундах: наружу уходит остаток, а не момент, — по тем
  же причинам, по которым так отдаются все остальные дедлайны стола.
  """
  @spec tournament(RoomState.t()) :: map() | nil
  def tournament(%RoomState{tournament: nil}), do: nil

  def tournament(%RoomState{tournament: tournament} = room) do
    %{
      level: tournament.level,
      next_level_in_ms: remaining(tournament.level_deadline_at),
      # Приза ещё нет, пока турнир не начался: он тянется до первой карты.
      prize: tournament.prize,
      buy_in: room.setting.buy_in,
      starting_stack: room.setting.starting_stack,
      players_left: RoomState.alive_count(room),
      standings: tournament.standings,
      finished: tournament.settled?
    }
  end

  # Розыгрыш кнопки в снапшоте: игрок, севший через `quick_seat`, подключается
  # к столу уже после старта розыгрыша и событие не застаёт. Карты открытые
  # и одинаковые для всех — прятать их нельзя.
  defp button_draw(%RoomState{button_draw: nil}), do: nil

  defp button_draw(%RoomState{button_draw: draw}) do
    remaining = draw.ends_at - System.monotonic_time(:millisecond)

    if remaining > 0 do
      %{cards: drawn_cards(draw.cards), button_seat: draw.button_seat, animation_ms: remaining}
    else
      nil
    end
  end

  @doc """
  Событие стола на пути в сокет. Карта внутри ядра — целое число ради
  скорости эквити-калькулятора; наружу она обязана уходить парой
  `%{rank, suit}`, иначе клиент получает бессмысленное `18`.
  """
  @spec event(String.t(), map()) :: map()
  def event("button_draw", payload) do
    Map.update(payload, :cards, [], &drawn_cards/1)
  end

  def event(_name, payload), do: payload

  defp drawn_cards(cards) do
    Enum.map(cards, fn %{seat: seat, card: card} -> %{seat: seat, card: Card.to_map(card)} end)
  end

  # Публичная часть раздачи. Что именно показать, решает дисциплина: view
  # не выбирает поля по виду игры и не считает ничего сам (§3 CLAUDE.md).
  # Дедлайн и тайм-банк добавляются здесь — они принадлежат столу, а не
  # раздаче, и хранятся в монотонных мс, которых наружу быть не должно.
  defp hand(%RoomState{hand: nil}), do: nil

  defp hand(%RoomState{hand: hand} = room) do
    hand
    |> room.discipline.public_view()
    |> cards()
    |> Map.merge(%{
      deadline_ms: remaining(room.deadline_at),
      # Идёт ли отсчёт из личного запаса: подключившийся в середине хода
      # должен увидеть тот же таймер, что и остальные.
      time_bank_running: room.time_bank_at != nil
    })
  end

  @doc """
  Карты в снапшоте дисциплины на пути в JSON.

  Внутри ядра карта — целое число, и превратить её в `%{rank, suit}` обязан
  транспорт: дисциплина помечает такие значения `{:card, _}` и `{:cards, _}`,
  а этот обход их разворачивает. Ветвления по дисциплине тут нет — метка
  одна на всех.
  """
  @spec cards(term()) :: term()
  def cards({:card, card}), do: Card.to_map(card)
  def cards({:cards, list}), do: Enum.map(list, &Card.to_map/1)
  def cards(%{} = map) when not is_struct(map), do: Map.new(map, fn {k, v} -> {k, cards(v)} end)
  def cards(list) when is_list(list), do: Enum.map(list, &cards/1)
  def cards(other), do: other

  defp remaining(nil), do: nil

  defp remaining(deadline_at) do
    max(deadline_at - System.monotonic_time(:millisecond), 0)
  end

  @spec seat(Seat.t(), Ecto.UUID.t()) :: map()
  def seat(%Seat{} = seat, _user_id) do
    %{
      seat: seat.number,
      status: seat.status,
      user_id: seat.user_id,
      name: seat.name,
      avatar: seat.avatar,
      # Косметика: во что её красить, решает клиент. Неизвестную метку он
      # рисует как обычную — новая косметика не требует его релиза.
      flair: seat.flair,
      stack: seat.stack,
      # Заказанная докупка публична по той же причине, что и страддл: она
      # меняет цену будущей раздачи для всех за столом, а не только для того,
      # кто её заказал.
      add_chips: RoomState.queued_add_chips(seat),
      waiting_for_bb: seat.waiting_for_bb,
      wants_post: seat.wants_post,
      missed_blinds: seat.missed_blinds,
      # Страддл публичен: стол обязан знать, что кто-то ставит вслепую, —
      # это меняет цену раздачи для всех, а не только для объявившего.
      straddle: seat.straddle,
      # Пауза публична: стол и так видит, что игрок раздачи пропускает, а
      # обратный отсчёт объясняет, сколько это кресло ещё будет занято.
      sit_out_pending: seat.sit_out_pending,
      sit_out_ms: remaining(seat.sit_out_until),
      # Запас времени публичен: соперник и так видит, что игрок думает
      # дольше обычного. А вот `preselect` — нет: заранее выбранный фолд
      # рассказал бы столу о руке раньше самого хода.
      time_bank: seat.time_bank,
      # Показатели публичны: они выводятся из действий, которые и так видел
      # весь стол. Проценты приходят из ядра посчитанными.
      stats: Stats.summary(seat.stats)
    }
  end

  defp you(room, user_id) do
    case RoomState.find_seat(room, user_id) do
      # Наблюдателю поле тоже приходит: клиент прячет панель по одному
      # признаку, а не по «сижу ли я» плюс «есть ли ключ».
      nil ->
        %{seated: false, can_react: false}

      seat ->
        %{
          seated: true,
          seat: seat.number,
          stack: seat.stack,
          add_chips: RoomState.queued_add_chips(seat),
          status: seat.status,
          waiting_for_bb: seat.waiting_for_bb,
          sit_out_pending: seat.sit_out_pending,
          sit_out_ms: remaining(seat.sit_out_until),
          post_required: seat.post_required,
          can_post: seat.can_post,
          wants_post: seat.wants_post,
          missed_blinds: seat.missed_blinds,
          time_bank: seat.time_bank,
          preselect: seat.preselect,
          straddle: seat.straddle,
          # Право на ручной запуск считает ядро; роль игрока наружу не уходит
          # ни здесь, ни где-либо ещё.
          can_start_manual: RoomState.can_start_manual?(room, user_id),
          can_react: RoomState.can_react?(room, user_id),
          # Rabbit hunting — только сидящему: наблюдатель этих карт не
          # получает ни в снапшоте, ни событием.
          rabbit: RoomState.rabbit_view(room, System.monotonic_time(:millisecond)),
          # Что игрок может показать столу после раздачи: свои карты и то,
          # какие из них ещё закрыты. Только владельцу — как и `hole_cards`.
          reveal: RoomState.reveal_view(room, user_id, System.monotonic_time(:millisecond))
        }
        |> Map.merge(private_hand(room, seat.number))
    end
  end

  # Свои карты, своя комбинация и свои легальные действия. Единственное
  # место, где приватное вообще попадает в снапшот, — и только владельцу.
  # Набор полей выбирает дисциплина: у раскладки это боксы и рука, у
  # холдема — карманные карты и легальные действия.
  defp private_hand(%RoomState{hand: nil}, _seat), do: %{}

  defp private_hand(%RoomState{hand: hand} = room, seat) do
    case room.discipline.private_view(hand, seat) do
      nil -> %{}
      view -> view |> cards() |> Map.update(:insight, nil, &insight/1)
    end
  end

  @doc """
  Разбор руки в JSON. Ничего не вычисляет: категория, играющие карты и
  число аутов приходят из `Engine.HandInsight` уже посчитанными.
  """
  @spec insight(HandInsight.t() | nil) :: map() | nil
  def insight(nil), do: nil

  def insight(%HandInsight{} = insight) do
    %{
      category: insight.category,
      complete: insight.complete,
      cards: Enum.map(insight.cards, &Card.to_map/1),
      draws:
        Enum.map(insight.draws, fn draw ->
          %{type: draw.type, outs: draw.outs, cards: Enum.map(draw.cards, &Card.to_map/1)}
        end)
    }
  end
end
