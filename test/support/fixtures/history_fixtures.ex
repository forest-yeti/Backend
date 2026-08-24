defmodule BlockPoker.HistoryFixtures do
  @moduledoc """
  Материал для тестов истории: раздача холдема, раздача китайского покера
  и вход турнира — собранные так, как их отдаёт `History.Build`.

  Строки собираются здесь напрямую, а не прогоном настоящей раздачи,
  потому что проверяется **запись**: идемпотентность, каскады, инкремент
  агрегата. Сборка из живой раздачи проверяется отдельно, на уровне 1, где
  ни БД, ни процессов нет.
  """

  alias BlockPoker.History.PlayerStatsDaily

  @doc "Раздача холдема: двое, один выиграл банк без вскрытия."
  def holdem_rows(overrides) do
    hand_id = Map.get(overrides, :hand_id, Ecto.UUID.generate())
    [winner, loser] = Map.fetch!(overrides, :users)
    day = Map.get(overrides, :day, Date.utc_today())
    ended_at = Map.get(overrides, :ended_at, DateTime.utc_now())
    setting_id = Map.get(overrides, :setting_id, PlayerStatsDaily.no_setting())
    mode = Map.get(overrides, :game_mode, :cash)

    %{
      kind: :holdem,
      hand: %{
        id: hand_id,
        room_id: Map.get(overrides, :room_id, Ecto.UUID.generate()),
        game_mode: mode,
        setting_id: setting_id,
        currency: Map.get(overrides, :currency, :main),
        tournament_id: overrides[:tournament_id],
        level_number: overrides[:level_number],
        hand_number: Map.get(overrides, :hand_number, 1),
        variant: "texas_holdem",
        button_seat: 1,
        bet_unit: 100,
        small_blind: 50,
        big_blind: 100,
        ante: 0,
        board: [],
        board_2: nil,
        bomb_pot: nil,
        pot: 300,
        rake: 0,
        pots: [%{run: 1, amount: 300, winners: [1], eligible: [1, 2]}],
        started_at: ended_at,
        ended_at: ended_at
      },
      players: [
        player_row(hand_id, winner, 1, %{
          hole_cards: [%{rank: 14, suit: "s"}, %{rank: 14, suit: "h"}],
          card_visibility: :hidden,
          invested: 150,
          won: 300,
          net: 150,
          status: :won_uncontested
        }),
        player_row(hand_id, loser, 2, %{
          hole_cards: [%{rank: 7, suit: "d"}, %{rank: 2, suit: "c"}],
          card_visibility: :hidden,
          invested: 150,
          won: 0,
          net: -150,
          status: :folded
        })
      ],
      actions: [
        action_row(hand_id, 1, :post_blind, 2, 50),
        action_row(hand_id, 2, :post_blind, 1, 100),
        action_row(hand_id, 3, :fold, 2, 0)
      ],
      stats: [
        stats_row(winner, day, mode, setting_id, %{
          net: 150,
          invested: 150,
          won: 300,
          bb_sum: 100,
          currency: Map.get(overrides, :currency, :main)
        }),
        stats_row(loser, day, mode, setting_id, %{
          net: -150,
          invested: 150,
          won: 0,
          bb_sum: 100,
          currency: Map.get(overrides, :currency, :main)
        })
      ]
    }
  end

  @doc "Раздача китайского покера: двое, попарный счёт замкнут в ноль."
  def ofc_rows(overrides) do
    hand_id = Map.get(overrides, :hand_id, Ecto.UUID.generate())
    [winner, loser] = Map.fetch!(overrides, :users)
    day = Map.get(overrides, :day, Date.utc_today())
    ended_at = Map.get(overrides, :ended_at, DateTime.utc_now())
    setting_id = Map.get(overrides, :setting_id, PlayerStatsDaily.no_setting())

    %{
      kind: :ofc,
      hand: %{
        id: hand_id,
        room_id: Map.get(overrides, :room_id, Ecto.UUID.generate()),
        game_mode: :ofc_cash,
        setting_id: setting_id,
        hand_number: 1,
        variant: "ofc_pineapple",
        button_seat: 1,
        point_value: 100,
        started_at: ended_at,
        ended_at: ended_at
      },
      players: [
        ofc_player_row(hand_id, winner, 1, %{points: 6, net: 600, scoop_count: 1}),
        ofc_player_row(hand_id, loser, 2, %{points: -6, net: -600, scoop_count: 0})
      ],
      actions: [],
      stats: [
        stats_row(winner, day, :ofc_cash, setting_id, %{net: 600, ofc_points: 6, scoops: 1}),
        stats_row(loser, day, :ofc_cash, setting_id, %{net: -600, ofc_points: -6})
      ]
    }
  end

  @doc "Итог турнирного входа."
  def tournament_result(overrides \\ %{}) do
    Map.merge(
      %{
        entry_id: Ecto.UUID.generate(),
        tournament_id: Ecto.UUID.generate(),
        user_id: nil,
        title: "Вечерний мейджор",
        tournament_setting_id: Ecto.UUID.generate(),
        format: :mtt,
        bounty: false,
        entry_kind: :initial,
        entry_index: 0,
        buy_in: 1000,
        entry_fee: 100,
        addons_count: 0,
        addons_cost: 0,
        prize: 0,
        bounty_paid: 0,
        bounty_final: 0,
        refund: 0,
        place: 12,
        entrants: 90,
        itm: false,
        outcome: :busted,
        hands_played: 40,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now()
      },
      overrides
    )
  end

  defp player_row(hand_id, user_id, seat, attrs) do
    Map.merge(
      %{
        hand_id: hand_id,
        user_id: user_id,
        seat: seat,
        position: if(seat == 1, do: :btn, else: :bb),
        starting_stack: 10_000,
        hole_cards: [],
        card_visibility: :hidden,
        invested: 0,
        won: 0,
        net: 0,
        ev_amount: nil,
        status: :folded,
        rank: nil
      },
      attrs
    )
  end

  defp ofc_player_row(hand_id, user_id, seat, attrs) do
    Map.merge(
      %{
        ofc_hand_id: hand_id,
        user_id: user_id,
        seat: seat,
        box: %{"top" => [], "middle" => [], "bottom" => []},
        discards: [%{rank: 3, suit: "c"}],
        foul: false,
        royalties: %{"top" => 0, "middle" => 0, "bottom" => 0},
        royalty_total: 0,
        fantasy: false,
        fantasy_next: false,
        fantasy_cards: nil,
        points: 0,
        net: 0,
        scoop_count: 0,
        line_results: []
      },
      attrs
    )
  end

  defp action_row(hand_id, seq, action, seat, amount) do
    %{
      hand_id: hand_id,
      seq: seq,
      street: :preflop,
      seat: seat,
      action: action,
      amount: amount,
      to_amount: amount,
      pot_before: 0,
      stack_after: 10_000 - amount,
      elapsed_ms: 0,
      auto: false
    }
  end

  defp stats_row(user_id, day, mode, setting_id, attrs) do
    PlayerStatsDaily.counters()
    |> Map.new(&{&1, 0})
    |> Map.merge(%{user_id: user_id, day: day, game_mode: mode, setting_id: setting_id, hands: 1})
    |> Map.merge(attrs)
  end
end
