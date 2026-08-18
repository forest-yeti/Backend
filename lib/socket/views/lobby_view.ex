defmodule Socket.Views.LobbyView do
  @moduledoc """
  Витрина лобби: список шаблонов с их комнатами.

  Транспорт, а не логика: решает, *какие* поля показать, но не вычисляет
  доменных значений. Всё, что здесь есть, приходит из ядра уже посчитанным.
  """

  alias BlockPoker.CashGames.CashGameSetting

  @spec render([map()]) :: %{settings: [map()]}
  def render(snapshot), do: %{settings: Enum.map(snapshot, &setting/1)}

  @spec setting(map()) :: map()
  def setting(%{setting: setting, rooms: rooms, players_total: players_total}) do
    %{
      setting_id: setting.id,
      name: CashGameSetting.display_name(setting),
      game_type: setting.game_type,
      currency: setting.currency,
      small_blind: setting.small_blind,
      big_blind: setting.big_blind,
      ante: setting.ante,
      ante_type: setting.ante_type,
      max_players: setting.max_players,
      min_buy_in: CashGameSetting.min_buy_in_chips(setting),
      max_buy_in: CashGameSetting.max_buy_in_chips(setting),
      players_total: players_total,
      visuals: visuals(setting),
      rooms: Enum.map(rooms, &room/1)
    }
  end

  @spec room(map()) :: map()
  def room(room) do
    %{
      room_id: room.room_id,
      seats_taken: room.seats_taken,
      max_players: room.max_players,
      draining: room.draining?
    }
  end

  @doc "Косметика стола: клиент рисует сукно и фон по этим значениям."
  @spec visuals(CashGameSetting.t()) :: map()
  def visuals(setting) do
    %{felt_color: setting.felt_color, background_color: setting.background_color}
  end
end
