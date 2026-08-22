defmodule Socket.Views.OfcLobbyView do
  @moduledoc """
  Витрина лобби китайского покера.

  Отдельный модуль, а не ветка в `LobbyView`: набор полей у строки другой —
  вместо блайндов, анте и бомб-пота здесь стоимость очка, и подмешивать
  нули холдемной формы было бы враньём в снапшоте.

  Транспорт, а не логика: решает, какие поля показать, но ничего не
  вычисляет — всё приходит из ядра посчитанным.
  """

  alias BlockPoker.Engine.Ofc
  alias BlockPoker.GameMode.OfcCash
  alias BlockPoker.OfcGames.OfcSetting
  alias Socket.Views.LobbyView

  @spec render([map()]) :: %{settings: [map()], filters: map()}
  def render(snapshot) do
    %{settings: Enum.map(snapshot, &setting/1), filters: BlockPoker.Tables.ofc_lobby_filters()}
  end

  @spec setting(map()) :: map()
  def setting(%{setting: setting, rooms: rooms, players_total: players_total} = snapshot) do
    %{
      setting_id: setting.id,
      name: OfcCash.name(setting),
      discipline: Ofc.Hand.id(),
      game_type: setting.game_type,
      currency: setting.currency,
      # Лимит стола — стоимость очка. Она же базовая единица, от которой
      # клиент считает бай-ин: второго номинала за этим столом нет.
      point_value: setting.point_value,
      bet_unit: OfcSetting.bet_unit(setting),
      max_players: setting.max_players,
      table_size: Map.get(snapshot, :table_size),
      limit_tier: Map.get(snapshot, :limit_tier),
      seats_taken: Map.get(snapshot, :seats_taken),
      min_buy_in: OfcSetting.min_buy_in_chips(setting),
      max_buy_in: OfcSetting.max_buy_in_chips(setting),
      players_total: players_total,
      visuals: LobbyView.visuals(setting),
      rooms: Enum.map(rooms, &LobbyView.room/1)
    }
  end

  @doc "Комната, найденная по коду: строка витрины плюс адрес комнаты."
  @spec found_room(map()) :: map()
  def found_room(%{setting: setting} = found) do
    range = BlockPoker.Tables.buy_in_range(setting)

    %{
      room_id: found.room_id,
      setting_id: setting.id,
      name: OfcCash.name(setting),
      discipline: Ofc.Hand.id(),
      game_type: setting.game_type,
      currency: setting.currency,
      point_value: setting.point_value,
      bet_unit: OfcSetting.bet_unit(setting),
      min_buy_in: range.min,
      max_buy_in: range.max,
      seats_taken: found.seats_taken,
      free_seats: found.free_seats,
      max_players: found.max_players,
      visuals: LobbyView.visuals(setting)
    }
  end
end
