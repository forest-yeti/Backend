defmodule BlockPoker.History.Summary do
  @moduledoc """
  Производные показатели из счётчиков агрегата.

  Живёт в ядре по той же причине, что и `Engine.Stats.summary/1`: деление
  — доменная арифметика, и одинаковое округление у всех потребителей
  важнее удобства (§3 CLAUDE.md). Транспорту остаётся отрендерить готовую
  карту.

  **Разрезы отличаются не оформлением, а набором осмысленных величин.**
  Показатель, которого в режиме не существует, не отдаётся вовсе: ноль
  вместо него читался бы как «пассивный игрок», а не как «неприменимо».
  Поэтому в китайском покере нет VPIP, PFR и WTSD — торговли там нет; в
  турнире нет bb/100 — величина большого блайнда меняется по уровням, и
  средневзвешенная цифра была бы ложью; там же не отдаётся `net` — он в
  турнирных фишках, а фишки не деньги, и складывать их с деньгами нечем.

  Дроби отдаются в **промилле-миллионных** целыми: делить деньги во view
  нельзя, а float в деньгах проекту запрещён.
  """

  alias BlockPoker.Engine.Stats

  @doc "Сводка одного режима по его дневным счётчикам."
  @spec mode(atom(), map()) :: map()
  def mode(:ofc_cash, row) do
    %{
      hands: row.hands,
      net: row.net,
      points: row.ofc_points,
      points_per_hand_ppm: per(row.ofc_points, row.hands),
      net_per_hand_ppm: per(row.net, row.hands),
      fantasy_rate: Stats.percent(row.fantasy_hands, row.hands),
      # Заходы считаются среди раздач, в которые игрок вошёл **без**
      # фантазии, удержания — среди тех, в которые вошёл с ней. Общий
      # знаменатель смешал бы две разные способности в одно число.
      fantasy_entry_rate: Stats.percent(row.fantasy_entries, row.hands - row.fantasy_hands),
      fantasy_hold_rate: Stats.percent(row.fantasy_holds, row.fantasy_hands),
      foul_rate: Stats.percent(row.fouls, row.hands),
      scoops: row.scoops,
      royalty_top_ppm: per(row.royalty_top, row.hands),
      royalty_middle_ppm: per(row.royalty_middle, row.hands),
      royalty_bottom_ppm: per(row.royalty_bottom, row.hands)
    }
  end

  def mode(:cash, row) do
    row
    |> behavioural()
    |> Map.merge(%{
      net: row.net,
      ev_net: row.ev_net,
      rake_paid: row.rake_paid,
      # bb/100: `net / bb_sum * 100`.
      winrate_ppm: per(row.net * 100, row.bb_sum),
      ev_winrate_ppm: per(row.ev_net * 100, row.bb_sum)
    })
  end

  def mode(_tournament, row), do: behavioural(row)

  defp behavioural(row) do
    %{
      hands: row.hands,
      vpip: Stats.percent(row.vpip, row.hands),
      pfr: Stats.percent(row.pfr, row.hands),
      three_bet: Stats.percent(row.three_bets, row.three_bet_chances),
      wtsd: Stats.percent(row.showdowns, row.saw_flop),
      af: aggression(row),
      # Сырые счётчики агрессии: по ним клиент отличает «коллов не было»
      # (AF не определён) от «игрок пассивен».
      aggressive_actions: row.aggressive,
      calls: row.calls
    }
  end

  defp aggression(%{calls: 0}), do: nil
  defp aggression(row), do: Float.round(row.aggressive / row.calls, 1)

  defp per(_part, 0), do: nil
  defp per(_part, nil), do: nil
  defp per(part, total), do: div(part * 1_000_000, total)
end
