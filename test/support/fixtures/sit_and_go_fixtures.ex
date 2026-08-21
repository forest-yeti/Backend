defmodule BlockPoker.SitAndGoFixtures do
  @moduledoc """
  Фикстуры Sit & Go.

  `build_setting/1` собирает шаблон **в памяти**, вместе с уровнями и
  тирами: тесты процессов не ходят в БД, а комната всё равно копирует
  настройки себе при старте и за строками не возвращается.
  """

  alias BlockPoker.SitAndGo.{BlindLevel, PrizeTier, SitAndGoSetting}

  @doc """
  Короткая структура из трёх уровней: гипер-лесенка нужна тестам ровно для
  того, чтобы проверить рост номиналов, а не чтобы доиграть турнир.
  """
  def blind_levels(overrides \\ []) do
    duration = Keyword.get(overrides, :duration_seconds, 180)

    [
      %{level: 1, small_blind: 10, big_blind: 20, ante: 0},
      %{level: 2, small_blind: 15, big_blind: 30, ante: 0},
      %{level: 3, small_blind: 20, big_blind: 40, ante: 0}
    ]
    |> Enum.map(
      &struct!(%BlindLevel{id: Ecto.UUID.generate()}, Map.put(&1, :duration_seconds, duration))
    )
  end

  @doc "Уровни на анте кнопки — структура ставок Short Deck."
  def ante_levels(overrides \\ []) do
    duration = Keyword.get(overrides, :duration_seconds, 180)

    [
      %{level: 1, small_blind: 0, big_blind: 0, ante: 10},
      %{level: 2, small_blind: 0, big_blind: 0, ante: 15}
    ]
    |> Enum.map(
      &struct!(%BlindLevel{id: Ecto.UUID.generate()}, Map.put(&1, :duration_seconds, duration))
    )
  end

  @doc """
  Вырожденная таблица призов: один тир с полным шансом.

  Розыгрыш проверяется в тестах `Engine.PrizePool`; здесь важна не
  случайность, а то, что стол её вообще тянет и кладёт результат.
  """
  def prize_tiers(tiers \\ [%{multiplier: 200, chance_ppm: 1_000_000, payouts: [100]}]) do
    Enum.map(tiers, &struct!(%PrizeTier{id: Ecto.UUID.generate()}, &1))
  end

  @doc "Турнирный шаблон в памяти со всем, что нужно комнате для старта."
  def build_setting(overrides \\ %{}) do
    levels = Map.get(overrides, :blind_levels, blind_levels())
    tiers = Map.get(overrides, :prize_tiers, prize_tiers())

    attrs =
      %{
        name: "Hyper 3-Max тест",
        game_type: :texas_holdem,
        currency: :play_money,
        max_players: 3,
        buy_in: 100,
        starting_stack: 500,
        action_timeout_ms: 15_000,
        time_bank_ms: 20_000,
        time_bank_refill: 5_000,
        disconnect_grace_ms: 30_000,
        button_draw_animation_ms: 3_000,
        prize_reveal_ms: 5_000,
        enabled: true
      }
      |> Map.merge(Map.drop(overrides, [:blind_levels, :prize_tiers]))

    struct!(
      %SitAndGoSetting{id: Ecto.UUID.generate(), blind_levels: levels, prize_tiers: tiers},
      attrs
    )
  end
end
