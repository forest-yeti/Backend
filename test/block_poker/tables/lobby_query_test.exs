defmodule BlockPoker.Tables.LobbyQueryTest do
  @moduledoc """
  Фильтры и порядок витрины лобби. Чистые функции: ни БД, ни процессов.
  """

  use ExUnit.Case, async: true

  import BlockPoker.CashGamesFixtures

  alias BlockPoker.Tables.LobbyQuery

  defp entry(overrides, seats_taken \\ 0) do
    %{setting: build_setting(overrides), seats_taken: seats_taken}
  end

  defp names(entries), do: Enum.map(entries, & &1.setting.name)

  defp query!(params) do
    {:ok, query} = LobbyQuery.parse(params)
    query
  end

  defp grid do
    [
      entry(%{name: "PM NL5000", currency: :play_money, small_blind: 25, big_blind: 50}, 4),
      entry(%{name: "NL10", currency: :main, small_blind: 5, big_blind: 10}, 6),
      entry(%{name: "PM NL1000", currency: :play_money, small_blind: 5, big_blind: 10}, 9),
      entry(%{name: "NL2", currency: :main, small_blind: 1, big_blind: 2}, 2),
      entry(%{name: "NL1000", currency: :main, small_blind: 500, big_blind: 1000}, 0)
    ]
  end

  describe "порядок по умолчанию" do
    test "сперва main от младшего лимита к старшему, затем play_money" do
      assert names(LobbyQuery.apply(query!(%{}), grid())) ==
               ["NL2", "NL10", "NL1000", "PM NL1000", "PM NL5000"]
    end

    test "пустой payload и nil дают тот же порядок" do
      assert LobbyQuery.parse(nil) == LobbyQuery.parse(%{})
    end
  end

  describe "категория лимита" do
    test "main: NL2..NL10 — микро, NL20..NL500 — средние, дальше хайроллеры" do
      assert LobbyQuery.limit_tier(build_setting(%{currency: :main, big_blind: 2})) == :micro
      assert LobbyQuery.limit_tier(build_setting(%{currency: :main, big_blind: 10})) == :micro
      assert LobbyQuery.limit_tier(build_setting(%{currency: :main, big_blind: 20})) == :medium
      assert LobbyQuery.limit_tier(build_setting(%{currency: :main, big_blind: 500})) == :medium

      assert LobbyQuery.limit_tier(build_setting(%{currency: :main, big_blind: 800})) ==
               :high_roller
    end

    test "play_money считается по своей лестнице" do
      pm = &build_setting(%{currency: :play_money, big_blind: &1})

      assert LobbyQuery.limit_tier(pm.(10)) == :micro
      assert LobbyQuery.limit_tier(pm.(100)) == :micro
      assert LobbyQuery.limit_tier(pm.(300)) == :medium
      assert LobbyQuery.limit_tier(pm.(1000)) == :high_roller
    end
  end

  describe "формат стола" do
    test "по количеству мест" do
      assert LobbyQuery.table_size(build_setting(%{max_players: 2})) == :heads_up
      assert LobbyQuery.table_size(build_setting(%{max_players: 6})) == :six_max
      assert LobbyQuery.table_size(build_setting(%{max_players: 9})) == :nine_max
    end
  end

  describe "фильтры" do
    test "валюта" do
      entries = LobbyQuery.apply(query!(%{"currencies" => ["play_money"]}), grid())
      assert names(entries) == ["PM NL1000", "PM NL5000"]
    end

    test "несколько категорий лимита складываются по «или»" do
      entries = LobbyQuery.apply(query!(%{"limit_tiers" => ["micro", "high_roller"]}), grid())

      # Средних (NL20..NL500) в выборке нет: PM NL5000 при bb 50 — микро
      # по лестнице игровых денег.
      assert names(entries) == ["NL2", "NL10", "NL1000", "PM NL1000", "PM NL5000"]

      medium = LobbyQuery.apply(query!(%{"limit_tiers" => ["medium"]}), grid())
      assert names(medium) == []
    end

    test "формат стола" do
      entries = [
        entry(%{name: "HU", max_players: 2}),
        entry(%{name: "6max", max_players: 6}),
        entry(%{name: "9max", max_players: 9})
      ]

      query = query!(%{"table_sizes" => ["heads_up", "nine_max"]})
      assert names(LobbyQuery.apply(query, entries)) == ["HU", "9max"]
    end

    test "категория игры" do
      query = query!(%{"game_types" => ["texas_holdem"]})
      assert length(LobbyQuery.apply(query, grid())) == 5
    end

    test "пустой список фильтром не считается" do
      assert names(LobbyQuery.apply(query!(%{"currencies" => []}), grid())) ==
               names(LobbyQuery.apply(query!(%{}), grid()))
    end

    test "неизвестное значение — ошибка, а не пустая витрина" do
      assert LobbyQuery.parse(%{"currencies" => ["bitcoin"]}) == {:error, :validation_failed}
      assert LobbyQuery.parse(%{"limit_tiers" => "micro"}) == {:error, :validation_failed}
      assert LobbyQuery.parse(%{"sort" => %{"field" => "rake"}}) == {:error, :validation_failed}

      assert LobbyQuery.parse(%{"sort" => %{"field" => "limit", "direction" => "up"}}) ==
               {:error, :validation_failed}
    end
  end

  describe "сортировка" do
    test "по лимиту в обе стороны, внутри своей валюты" do
      asc = query!(%{"sort" => %{"field" => "limit", "direction" => "asc"}})
      desc = query!(%{"sort" => %{"field" => "limit", "direction" => "desc"}})

      assert names(LobbyQuery.apply(asc, grid())) ==
               ["NL2", "NL10", "NL1000", "PM NL1000", "PM NL5000"]

      assert names(LobbyQuery.apply(desc, grid())) ==
               ["NL1000", "NL10", "NL2", "PM NL5000", "PM NL1000"]
    end

    test "по занятости мест" do
      asc = query!(%{"sort" => %{"field" => "occupancy", "direction" => "asc"}})
      desc = query!(%{"sort" => %{"field" => "occupancy", "direction" => "desc"}})

      main = Enum.filter(grid(), &(&1.setting.currency == :main))

      assert names(LobbyQuery.apply(asc, main)) == ["NL1000", "NL2", "NL10"]
      assert names(LobbyQuery.apply(desc, main)) == ["NL10", "NL2", "NL1000"]
    end

    test "направление по умолчанию — по возрастанию" do
      assert query!(%{"sort" => %{"field" => "limit"}}) ==
               query!(%{"sort" => %{"field" => "limit", "direction" => "asc"}})
    end
  end

  describe "matches?/2" do
    test "решает судьбу инкрементального обновления" do
      query = query!(%{"currencies" => ["main"]})

      assert LobbyQuery.matches?(query, entry(%{currency: :main}))
      refute LobbyQuery.matches?(query, entry(%{currency: :play_money}))
    end
  end
end
