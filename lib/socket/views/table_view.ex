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

  alias BlockPoker.CashGames.CashGameSetting
  alias BlockPoker.Engine.Card
  alias BlockPoker.Engine.Hand
  alias BlockPoker.Engine.Stats
  alias BlockPoker.Tables.{RoomState, Seat}
  alias Socket.Views.LobbyView

  @doc "Полный персональный снапшот — после join и после реконнекта."
  @spec render(RoomState.t(), Ecto.UUID.t()) :: map()
  def render(%RoomState{} = room, user_id) do
    %{
      room_id: room.room_id,
      setting_id: room.setting.id,
      name: CashGameSetting.display_name(room.setting),
      game_type: room.setting.game_type,
      betting_structure: CashGameSetting.structure(room.setting).id(),
      small_blind: room.setting.small_blind,
      big_blind: room.setting.big_blind,
      ante: room.setting.ante,
      # Номинал, от которого клиент считает шаги ползунка ставки. Приходит
      # посчитанным: выбирать между блайндом и анте — это ветвление по
      # правилам игры, которого в транспорте быть не может (§3 CLAUDE.md).
      bet_unit: RoomState.bet_unit(room),
      max_players: room.setting.max_players,
      timings: timings(room.setting),
      action_seq: room.action_seq,
      phase: room.phase,
      button_seat: room.button_seat,
      hands_played: room.hands_played,
      visuals: LobbyView.visuals(room.setting),
      seats: room |> RoomState.seats() |> Enum.map(&seat(&1, user_id)),
      button_draw: button_draw(room),
      hand: hand(room),
      showdown: room.showdown,
      chat: room.chat,
      # Панель реакций рисуется ровно этим списком и в этом порядке.
      reactions: BlockPoker.Tables.reactions(),
      you: you(room, user_id)
    }
  end

  @doc """
  Тайминги комнаты: всё, по чему клиент рисует обратный отсчёт.

  Они приходят в снапшоте, а не зашиты в клиент, потому что принадлежат
  шаблону комнаты: у хедз-апа, турнира и sit-n-go они разные, а правит их
  оператор в БД без релиза клиента.
  """
  @spec timings(CashGameSetting.t()) :: map()
  def timings(setting) do
    %{
      action_timeout_ms: setting.action_timeout_ms,
      time_bank_ms: setting.time_bank_ms,
      time_bank_refill: setting.time_bank_refill,
      disconnect_grace_ms: setting.disconnect_grace_ms,
      rebuy_prompt_ms: setting.rebuy_prompt_ms
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

  # Публичная часть раздачи: борд, банк, чей ход. Карманных карт здесь нет
  # и быть не может — они уходят только владельцу места.
  defp hand(%RoomState{hand: nil}), do: nil

  defp hand(%RoomState{hand: hand} = room) do
    %{
      street: hand.street,
      board: Enum.map(hand.board, &Card.to_map/1),
      pot: hand.pot,
      bet: hand.bet,
      to_act: hand.to_act,
      action_seq: hand.seq,
      deadline_ms: remaining(room.deadline_at),
      # Идёт ли отсчёт из личного запаса: подключившийся в середине хода
      # должен увидеть тот же таймер, что и остальные.
      time_bank_running: room.time_bank_at != nil,
      seats:
        Map.new(hand.players, fn {seat, player} ->
          {seat,
           %{
             committed: player.committed,
             total: player.total,
             status: player.status,
             cards: if(player.show?, do: Enum.map(player.hole, &Card.to_map/1))
           }}
        end)
    }
  end

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
      stack: seat.stack,
      waiting_for_bb: seat.waiting_for_bb,
      wants_post: seat.wants_post,
      missed_blinds: seat.missed_blinds,
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
          status: seat.status,
          waiting_for_bb: seat.waiting_for_bb,
          post_required: seat.post_required,
          can_post: seat.can_post,
          wants_post: seat.wants_post,
          missed_blinds: seat.missed_blinds,
          time_bank: seat.time_bank,
          preselect: seat.preselect,
          # Право на ручной запуск считает ядро; роль игрока наружу не уходит
          # ни здесь, ни где-либо ещё.
          can_start_manual: RoomState.can_start_manual?(room, user_id),
          can_react: RoomState.can_react?(room, user_id),
          # Rabbit hunting — только сидящему: наблюдатель этих карт не
          # получает ни в снапшоте, ни событием.
          rabbit: RoomState.rabbit_view(room, System.monotonic_time(:millisecond))
        }
        |> Map.merge(private_hand(room, seat.number))
    end
  end

  # Свои карты, своя комбинация и свои легальные действия. Единственное
  # место, где приватное вообще попадает в снапшот, — и только владельцу.
  defp private_hand(%RoomState{hand: nil}, _seat), do: %{}

  defp private_hand(%RoomState{hand: hand}, seat) do
    case Map.get(hand.players, seat) do
      nil ->
        %{}

      player ->
        %{
          hole_cards: Enum.map(player.hole, &Card.to_map/1),
          combination: combination(hand, seat),
          in_hand: player.status != :folded,
          legal_actions: Hand.legal_actions(hand, seat)
        }
    end
  end

  # Комбинация появляется с флопа: раньше пяти карт просто не набирается.
  defp combination(hand, seat) do
    case Hand.combination(hand, seat) do
      nil -> nil
      rank -> %{category: rank.category, cards: Enum.map(rank.cards, &Card.to_map/1)}
    end
  end
end
