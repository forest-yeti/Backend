defmodule BlockPoker.OfcGamesTest do
  @moduledoc """
  Сетка лимитов китайского покера: разворачивание и идемпотентность сида
  на настоящей MySQL.
  """

  use BlockPoker.DataCase, async: false

  alias BlockPoker.OfcGames
  alias BlockPoker.OfcGames.Grid

  describe "mix ofc.seed" do
    test "разворачивает 15 шаблонов: 9 уровней main и 6 play money, по одному формату" do
      rows = Grid.expand()

      assert length(rows) == 15
      assert Enum.count(rows, &(&1.attrs.currency == :main)) == 9
      assert Enum.count(rows, &(&1.attrs.currency == :play_money)) == 6
    end

    test "сетка сажает троих: хедз-ап разворачивается только вручную" do
      assert Grid.expand() |> Enum.map(& &1.attrs.max_players) |> Enum.uniq() == [3]
    end

    test "вход всегда стоит 100 очков — номинал в центах равен цене входа" do
      rows = Grid.expand(currency: :main)

      assert Enum.all?(rows, &(&1.attrs.min_buy_in == 100 and &1.attrs.max_buy_in == 100))
      assert Enum.map(rows, & &1.attrs.point_value) == [1, 2, 5, 10, 25, 50, 100, 250, 500]
      assert Enum.map(rows, & &1.attrs.name) |> List.first() == "0.01 C"
    end

    test "у play money и main разная косметика стола" do
      [main | _rest] = Grid.expand(currency: :main)
      [play | _rest] = Grid.expand(currency: :play_money)

      assert main.attrs.felt_color != play.attrs.felt_color
      assert String.match?(main.attrs.background_color, ~r/^#[0-9A-F]{6}$/i)
    end

    test "фильтр по уровню отбирает только названные лимиты" do
      rows = Grid.expand(currency: :main, only: ["OFC5", "OFC50"])

      assert Enum.map(rows, & &1.level) == ["OFC5", "OFC50"]
    end

    test "повторный прогон не создаёт дублей и не трогает существующие строки" do
      rows = Grid.expand(currency: :play_money, only: ["OFC1000"])

      first = Grid.seed(rows)
      assert length(first.created) == 1

      second = Grid.seed(rows)
      assert second.created == []
      assert length(second.skipped) == 1
      assert length(OfcGames.list_settings()) == 1
    end

    test "--force обновляет строку, но не воскрешает выключенный оператором лимит" do
      rows = Grid.expand(currency: :play_money, only: ["OFC1000"])
      Grid.seed(rows)

      [setting] = OfcGames.list_settings()
      {:ok, _off} = OfcGames.set_enabled(setting, false)

      result = Grid.seed(rows, force: true)

      assert length(result.updated) == 1
      assert [%{enabled: false}] = OfcGames.list_settings()
    end

    test "приватка на сеточных лимитах не ломает сид" do
      rows = Grid.expand(currency: :play_money, only: ["OFC1000"])
      [%{attrs: attrs} | _rest] = rows

      # Закрытая комната заняла естественный ключ уровня. Сид обязан её
      # пропустить: создать вторую строку база не даст, а перезаписать
      # чужой стол с кодом он не вправе.
      {:ok, _private} =
        OfcGames.create_private_setting(%{
          currency: attrs.currency,
          point_value: attrs.point_value,
          max_players: attrs.max_players
        })

      result = Grid.seed(rows, force: true)

      assert result.created == []
      assert result.updated == []
      assert length(result.skipped) == 1
      assert [%{visibility: :private}] = OfcGames.list_settings()
    end
  end
end
