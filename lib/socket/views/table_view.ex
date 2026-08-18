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
      you: you(room, user_id)
    }
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
    end
  end
end
