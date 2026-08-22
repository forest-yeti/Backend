# Лестница лимитов китайского покера — данные, а не код.
#
# Номинал стола здесь — **стоимость очка**, а не блайнд: у дисциплины без
# банка блайндов нет вовсе. Ею стол и подписан в витрине, и бай-ин на всей
# лестнице один: 100 очков. Ключ уровня `OFCx` (для `--only`) называет цену
# входа: `point_value = x / 100`.
#
# Суммы — целые в минимальных единицах: центы для `main`, фишки для `play_money`.

%{
  # Форматы, в которых разворачивается каждый уровень. Ананас сажает двоих
  # или троих (`Engine.Ofc.Hand.min_players/0`..`max_players/0`); сетка
  # разворачивает только троих — это решение сетки, а не правило. Хедз-ап
  # не запрещён нигде и появится добавлением строки сюда.
  formats: [
    %{max_players: 3}
  ],

  # Общие для всей сетки значения. Меняются здесь, а не в коде задачи.
  #
  # Бай-ин фиксированный: `min = max = 100` очков. У стола без банка стек не
  # даёт преимущества позиции и не меняет ставку — единственное, на что он
  # влияет, это сколько раздач игрок продержится до ребая. Разброс входа
  # здесь не создаёт форматов, а только разъезжает столы по глубине.
  defaults: %{
    game_type: :texas_holdem,
    min_buy_in: 100,
    max_buy_in: 100,
    action_timeout_ms: 30_000,
    time_bank_ms: 60_000,
    time_bank_refill: 15_000,
    disconnect_grace_ms: 30_000,
    sit_out_timeout_ms: 300_000,
    rebuy_prompt_ms: 60_000,
    button_draw_animation_ms: 3_000,
    auto_start: true,
    max_rooms: 100,
    visibility: :public,
    enabled: true
  },

  # Косметика стола по валюте: сукно и фон. На правила не влияет.
  visuals: %{
    main: %{felt_color: "#1F6F4A", background_color: "#10241C"},
    play_money: %{felt_color: "#2A5FA8", background_color: "#14203A"}
  },
  # `level` — короткий ключ уровня для `--only`; `name` — подпись в витрине.
  # Подпись называет стоимость очка в валютных единицах: у стола без банка
  # это тот же вопрос, на который у кэша отвечают блайнды.
  levels: %{
    main: [
      %{level: "OFC1", name: "0.01 C", point_value: 1},
      %{level: "OFC2", name: "0.02 C", point_value: 2},
      %{level: "OFC5", name: "0.05 C", point_value: 5},
      %{level: "OFC10", name: "0.1 C", point_value: 10},
      %{level: "OFC25", name: "0.25 C", point_value: 25},
      %{level: "OFC50", name: "0.5 C", point_value: 50},
      %{level: "OFC100", name: "1 C", point_value: 100},
      %{level: "OFC250", name: "2.5 C", point_value: 250},
      %{level: "OFC500", name: "5 C", point_value: 500}
    ],
    play_money: [
      %{level: "OFC1000", name: "10 C", point_value: 10},
      %{level: "OFC5000", name: "50 C", point_value: 50},
      %{level: "OFC10000", name: "100 C", point_value: 100},
      %{level: "OFC50000", name: "500 C", point_value: 500},
      %{level: "OFC100000", name: "1000 C", point_value: 1000},
      %{level: "OFC500000", name: "5000 C", point_value: 5000}
    ]
  }
}
