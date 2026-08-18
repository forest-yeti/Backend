# Бенчмарк калькулятора эквити (§8 задачи 2).
#
#     mix bench
#
# Бюджет, за который отвечает этот файл: флоп на двух известных руках —
# меньше 50 мс, флоп на девяти — меньше 300 мс. Без замера оптимизация
# превращается в угадывание, поэтому бенчмарк живёт в репозитории,
# а не в чьей-то консоли.

alias BlockPoker.Engine.{Card, Equity, HandRank, Rng, Variant}

holdem = Variant.TexasHoldem
hand = &Card.parse_many!/1

two_players = [{:a, hand.("AH KH")}, {:b, hand.("9S 9D")}]

nine_players = [
  {:a, hand.("AH KH")},
  {:b, hand.("9S 9D")},
  {:c, hand.("JC TC")},
  {:d, hand.("4S 4D")},
  {:e, hand.("QH QD")},
  {:f, hand.("8C 6C")},
  {:g, hand.("AS JD")},
  {:h, hand.("KS 5S")},
  {:i, hand.("3H 3D")}
]

flop = hand.("2H 7H TD")
context = HandRank.context(holdem)
seven_cards = hand.("AH KH 2H 7H TD 9C 4S")

Benchee.run(
  %{
    "оценка семи карт" => fn -> HandRank.best_hand(seven_cards, context) end,
    "флоп, 2 игрока (точно)" => fn ->
      Equity.equity(two_players, flop, holdem, mode: :exact, outs: false)
    end,
    "флоп, 2 игрока (с аутами)" => fn ->
      Equity.equity(two_players, flop, holdem, mode: :exact)
    end,
    "флоп, 9 игроков (точно)" => fn ->
      Equity.equity(nine_players, flop, holdem, mode: :exact, outs: false)
    end,
    "префлоп all-in, 2 игрока (Монте-Карло, 100k)" => fn ->
      Equity.equity(two_players, [], holdem,
        iterations: 100_000,
        rng: Rng.seeded("bench"),
        outs: false
      )
    end
  },
  time: 5,
  warmup: 2,
  memory_time: 0,
  print: [fast_warning: false]
)
