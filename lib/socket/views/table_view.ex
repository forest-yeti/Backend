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
  alias BlockPoker.Tables.{RoomState, Seat}
  alias Socket.Views.LobbyView

  @doc "Полный персональный снапшот — после join и после реконнекта."
  @spec render(RoomState.t(), Ecto.UUID.t()) :: map()
  def render(%RoomState{} = room, user_id) do
    %{
      room_id: room.room_id,
      setting_id: room.setting.id,
      name: CashGameSetting.display_name(room.setting),
      small_blind: room.setting.small_blind,
      big_blind: room.setting.big_blind,
      ante: room.setting.ante,
      max_players: room.setting.max_players,
      action_seq: room.action_seq,
      phase: room.phase,
      button_seat: room.button_seat,
      hands_played: room.hands_played,
      visuals: LobbyView.visuals(room.setting),
      seats: room |> RoomState.seats() |> Enum.map(&seat(&1, user_id)),
      button_draw: button_draw(room),
      hand: hand(room),
      you: you(room, user_id)
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
      missed_blinds: seat.missed_blinds
    }
  end

  defp you(room, user_id) do
    case RoomState.find_seat(room, user_id) do
      nil ->
        %{seated: false}

      seat ->
        %{
          seated: true,
          seat: seat.number,
          stack: seat.stack,
          status: seat.status,
          waiting_for_bb: seat.waiting_for_bb,
          post_required: seat.post_required,
          can_post: seat.can_post,
          missed_blinds: seat.missed_blinds
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
