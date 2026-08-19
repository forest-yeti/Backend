defmodule Socket.Views.LobbyView do
  @moduledoc """
  Витрина лобби: список шаблонов с их комнатами.

  Транспорт, а не логика: решает, *какие* поля показать, но не вычисляет
  доменных значений. Всё, что здесь есть, приходит из ядра уже посчитанным.
  """

  alias BlockPoker.CashGames.CashGameSetting

  @spec render([map()]) :: %{settings: [map()], filters: map()}
  def render(snapshot) do
    %{settings: Enum.map(snapshot, &setting/1), filters: BlockPoker.Tables.lobby_filters()}
  end

  @spec setting(map()) :: map()
  def setting(%{setting: setting, rooms: rooms, players_total: players_total} = snapshot) do
    %{
      setting_id: setting.id,
      name: CashGameSetting.display_name(setting),
      game_type: setting.game_type,
      currency: setting.currency,
      betting_structure: CashGameSetting.structure(setting).id(),
      small_blind: setting.small_blind,
      big_blind: setting.big_blind,
      ante: setting.ante,
      ante_type: setting.ante_type,
      bet_unit: CashGameSetting.bet_unit(setting),
      max_players: setting.max_players,
      table_size: entry_field(snapshot, :table_size),
      limit_tier: entry_field(snapshot, :limit_tier),
      seats_taken: entry_field(snapshot, :seats_taken),
      min_buy_in: CashGameSetting.min_buy_in_chips(setting),
      max_buy_in: CashGameSetting.max_buy_in_chips(setting),
      players_total: players_total,
      visuals: visuals(setting),
      rooms: Enum.map(rooms, &room/1)
    }
  end

  @doc """
  Комната, найденная по коду: то же, что строка лобби, плюс адрес комнаты —
  клиенту остаётся выбрать стек и отправить `join_seat`.
  """
  @spec found_room(map()) :: map()
  def found_room(%{setting: setting} = found) do
    range = BlockPoker.Tables.buy_in_range(setting)

    %{
      room_id: found.room_id,
      setting_id: setting.id,
      name: CashGameSetting.display_name(setting),
      game_type: setting.game_type,
      currency: setting.currency,
      betting_structure: CashGameSetting.structure(setting).id(),
      small_blind: setting.small_blind,
      big_blind: setting.big_blind,
      ante: setting.ante,
      ante_type: setting.ante_type,
      bet_unit: CashGameSetting.bet_unit(setting),
      min_buy_in: range.min,
      max_buy_in: range.max,
      seats_taken: found.seats_taken,
      free_seats: found.free_seats,
      max_players: found.max_players,
      visuals: visuals(setting)
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

  # Категория лимита, формат стола и занятость приходят из ядра посчитанными:
  # арифметике и правилам во view места нет (§3 CLAUDE.md).
  defp entry_field(snapshot, key), do: Map.get(snapshot, key)

  @doc "Косметика стола: клиент рисует сукно и фон по этим значениям."
  @spec visuals(CashGameSetting.t()) :: map()
  def visuals(setting) do
    %{felt_color: setting.felt_color, background_color: setting.background_color}
  end

  @doc """
  Занятые игроком места. Список плоский: за одним лимитом можно сидеть в
  нескольких комнатах, и группировать их по шаблону значило бы решать за
  клиента, как он их покажет.
  """
  @spec my_seats([map()]) :: map()
  def my_seats(seats) do
    %{
      seats:
        Enum.map(seats, fn seat ->
          %{
            room_id: seat.room_id,
            setting_id: seat.setting_id,
            seat: seat.seat,
            stack: seat.stack,
            status: seat.status
          }
        end)
    }
  end
end
