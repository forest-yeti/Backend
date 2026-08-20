# Лестница лимитов кэш-игры — данные, а не код (§8 задачи 3).
#
# Правило вывода уровня: `NLx` — это стол, где 100bb стоят `x`, то есть
# `bb = x / 100`, `sb = bb / 2`. Единственное исключение — NL5: отраслевой
# стандарт 0.02/0.05, пополам не делится.
#
# Суммы — целые в минимальных единицах: центы для `main`, фишки для `play_money`.
# Рейк здесь **нулевой** намеренно: значения задаёт оператор в БД.

%{
  # Форматы, в которых разворачивается каждый уровень.
  # Формат может сменить и вид покера: Short Deck разворачивается на той же
  # лестнице лимитов, что и холдем, — номиналом стола становится анте,
  # равное большому блайнду уровня, а блайндов у такого стола нет вовсе.
  # Пока разворачивается только 6-max — это решение сетки, а не правило:
  # ни 9-max, ни хедз-ап для Short Deck нигде не запрещены, и появятся они
  # добавлением строки сюда.
  formats: [
    %{suffix: "6-max", max_players: 6, ante: :none},
    %{suffix: "6-max Ante", max_players: 6, ante: :half_big_blind},
    %{suffix: "9-max", max_players: 9, ante: :none},
    %{suffix: "HU", max_players: 2, ante: :none},
    %{suffix: "Short Deck 6-max", max_players: 6, ante: :big_blind, game_type: :short_deck}
  ],

  # Общие для всей сетки значения. Меняются здесь, а не в коде задачи.
  defaults: %{
    game_type: :texas_holdem,
    min_buy_in: 40,
    max_buy_in: 100,
    ante_type: :big_blind,
    rake_percent: 0,
    rake_cap_by_players: %{},
    no_flop_no_drop: true,
    action_timeout_ms: 20_000,
    time_bank_ms: 30_000,
    time_bank_refill: 10_000,
    disconnect_grace_ms: 30_000,
    sit_out_timeout_ms: 300_000,
    rebuy_prompt_ms: 60_000,
    button_draw_animation_ms: 3_000,
    allow_post_blind: true,
    auto_start: true,
    blind_dodge_window_hands: 10,
    max_rooms: 100,
    visibility: :public,
    enabled: true
  },

  # Косметика стола по валюте: сукно и фон. На правила не влияет.
  visuals: %{
    main: %{felt_color: "#1F6F4A", background_color: "#10241C"},
    play_money: %{felt_color: "#2A5FA8", background_color: "#14203A"}
  },

  levels: %{
    main: [
      %{level: "NL2", small_blind: 1, big_blind: 2},
      %{level: "NL5", small_blind: 2, big_blind: 5},
      %{level: "NL10", small_blind: 5, big_blind: 10},
      %{level: "NL20", small_blind: 10, big_blind: 20},
      %{level: "NL50", small_blind: 25, big_blind: 50},
      %{level: "NL100", small_blind: 50, big_blind: 100},
      %{level: "NL200", small_blind: 100, big_blind: 200},
      %{level: "NL500", small_blind: 250, big_blind: 500},
      %{level: "NL800", small_blind: 400, big_blind: 800},
      %{level: "NL1000", small_blind: 500, big_blind: 1000},
      %{level: "NL2000", small_blind: 1000, big_blind: 2000},
      %{level: "NL5000", small_blind: 2500, big_blind: 5000}
    ],
    play_money: [
      %{level: "NL1000", small_blind: 5, big_blind: 10},
      %{level: "NL5000", small_blind: 25, big_blind: 50},
      %{level: "NL10000", small_blind: 50, big_blind: 100},
      %{level: "NL30000", small_blind: 150, big_blind: 300},
      %{level: "NL50000", small_blind: 250, big_blind: 500},
      %{level: "NL100000", small_blind: 500, big_blind: 1000}
    ]
  }
}
