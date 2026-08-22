defmodule BlockPoker.CashGamesTest do
  @moduledoc """
  Шаблоны кэш-игры: валидации и идемпотентность сида на настоящей MySQL.
  """

  use BlockPoker.DataCase, async: false

  import BlockPoker.CashGamesFixtures

  alias BlockPoker.CashGames
  alias BlockPoker.CashGames.{CashGameSetting, Grid}
  alias BlockPoker.Engine.BettingStructure

  describe "валидация" do
    test "большой блайнд обязан быть больше малого" do
      {:error, changeset} =
        CashGames.create_setting(valid_setting_attrs(%{small_blind: 10, big_blind: 10}))

      assert %{big_blind: [_message]} = errors_on(changeset)
    end

    test "мест не больше девяти" do
      {:error, changeset} = CashGames.create_setting(valid_setting_attrs(%{max_players: 10}))

      assert %{max_players: [_message]} = errors_on(changeset)
    end

    test "мест не меньше двух" do
      {:error, changeset} = CashGames.create_setting(valid_setting_attrs(%{max_players: 1}))

      assert %{max_players: [_message]} = errors_on(changeset)
    end

    test "рейк не превышает 10%" do
      {:error, changeset} = CashGames.create_setting(valid_setting_attrs(%{rake_percent: 1001}))

      assert %{rake_percent: [_message]} = errors_on(changeset)
    end

    test "минимальный бай-ин не ниже 20 больших блайндов" do
      {:error, changeset} = CashGames.create_setting(valid_setting_attrs(%{min_buy_in: 19}))

      assert %{min_buy_in: [_message]} = errors_on(changeset)
    end

    test "максимальный бай-ин не ниже минимального" do
      {:error, changeset} =
        CashGames.create_setting(valid_setting_attrs(%{min_buy_in: 100, max_buy_in: 40}))

      assert %{max_buy_in: [_message]} = errors_on(changeset)
    end

    test "стол без верхнего лимита допустим" do
      assert {:ok, setting} = CashGames.create_setting(valid_setting_attrs(%{max_buy_in: nil}))
      assert CashGameSetting.max_buy_in_chips(setting) == nil
    end

    test "капы рейка: обязателен ключ 2" do
      {:error, changeset} =
        CashGames.create_setting(valid_setting_attrs(%{rake_cap_by_players: %{"3" => 100}}))

      assert %{rake_cap_by_players: [_message]} = errors_on(changeset)
    end

    test "капы рейка: ключ не может превышать max_players" do
      {:error, changeset} =
        CashGames.create_setting(
          valid_setting_attrs(%{max_players: 6, rake_cap_by_players: %{"2" => 50, "9" => 100}})
        )

      assert %{rake_cap_by_players: [_message]} = errors_on(changeset)
    end

    test "цвета стола должны быть hex" do
      {:error, changeset} =
        CashGames.create_setting(valid_setting_attrs(%{felt_color: "зелёный"}))

      assert %{felt_color: [_message]} = errors_on(changeset)
    end

    test "цвета сохраняются и имеют дефолты" do
      setting = setting_fixture(%{felt_color: "#123456"})

      assert setting.felt_color == "#123456"
      assert setting.background_color == "#10241C"
    end

    test "естественный ключ уникален" do
      attrs = valid_setting_attrs(%{})
      {:ok, _first} = CashGames.create_setting(attrs)

      assert {:error, changeset} = CashGames.create_setting(attrs)
      assert changeset.errors != []
    end
  end

  describe "производные величины" do
    test "бай-ин пересчитывается из больших блайндов в фишки" do
      setting = setting_fixture(%{big_blind: 10, min_buy_in: 40, max_buy_in: 100})

      assert CashGameSetting.min_buy_in_chips(setting) == 400
      assert CashGameSetting.max_buy_in_chips(setting) == 1000
    end

    test "потолок рейка берётся по ближайшему меньшему ключу" do
      setting =
        setting_fixture(%{
          max_players: 9,
          rake_cap_by_players: %{"2" => 100, "3" => 200, "5" => 300}
        })

      assert CashGameSetting.rake_cap(setting, 2) == 100
      assert CashGameSetting.rake_cap(setting, 4) == 200
      assert CashGameSetting.rake_cap(setting, 9) == 300
    end

    test "имя генерируется из лимитов, если не задано" do
      setting = setting_fixture(%{name: nil, small_blind: 5, big_blind: 10, max_players: 6})

      assert CashGameSetting.display_name(setting) == "5/10 6-max"
    end

    # Стрижка имени смотрит только на три поля, и записывать ради неё
    # валидный шаблон в БД незачем — сравниваем на голой структуре.
    test "из имени вырезается то, что лобби показывает отдельными полями" do
      assert named("NL1000 Short Deck 6-max", :short_deck, 6) == "NL1000"
      assert named("NL1000 ShortDeck 6-max", :short_deck, 6) == "NL1000"
      assert named("NL10 Holdem 9-max", :texas_holdem, 9) == "NL10"
      assert named("NL5 HU", :texas_holdem, 2) == "NL5"
    end

    test "незнакомая часть имени сохраняется в скобках" do
      assert named("NL5 6-max Ante", :texas_holdem, 6) == "NL5 (Ante)"

      # Уже короткое имя стрижка не портит — прогон идемпотентен.
      assert named("NL5 (Ante)", :texas_holdem, 6) == "NL5 (Ante)"

      # «HU» на шестимаксе размером стола быть не может — значит, это факт.
      assert named("NL5 HU", :texas_holdem, 6) == "NL5 (HU)"
    end
  end

  describe "mix cash_game.seed" do
    test "разворачивает 90 шаблонов: 12 уровней main и 6 play money, по пять форматов" do
      rows = Grid.expand()

      assert length(rows) == 90
      assert Enum.count(rows, &(&1.attrs.currency == :main)) == 60
      assert Enum.count(rows, &(&1.attrs.currency == :play_money)) == 30
    end

    test "Short Deck разворачивается по всей лестнице лимитов, только 6-max" do
      short_deck = Grid.expand() |> Enum.filter(&(&1.attrs.game_type == :short_deck))

      # По одному столу на каждый уровень обеих валют.
      assert length(short_deck) == 18
      assert Enum.map(short_deck, & &1.attrs.max_players) |> Enum.uniq() == [6]

      # Блайндов у анте-стола нет, номинал — анте, равное bb уровня.
      assert Enum.all?(short_deck, &(&1.attrs.small_blind == 0 and &1.attrs.big_blind == 0))
      assert Enum.all?(short_deck, &(&1.attrs.ante > 0))
    end

    test "анте на Ante-столах — половина большого блайнда" do
      rows =
        Grid.expand(currency: :main, only: ["NL5", "NL10"])
        |> Enum.filter(&(&1.attrs.game_type == :texas_holdem))

      ante_rows = Enum.filter(rows, &(&1.attrs.ante > 0))
      # NL5: bb 5 -> анте 2 (округление вниз); NL10: bb 10 -> анте 5.
      assert Enum.map(ante_rows, & &1.attrs.ante) |> Enum.sort() == [2, 5]
    end

    test "сид проставляет нулевой рейк: значения задаёт оператор" do
      assert Enum.all?(Grid.expand(), &(&1.attrs.rake_percent == 0))
      assert Enum.all?(Grid.expand(), &(&1.attrs.rake_cap_by_players == %{}))
    end

    test "у play money и main разная косметика стола" do
      [main | _rest] = Grid.expand(currency: :main)
      [play | _rest] = Grid.expand(currency: :play_money)

      assert main.attrs.felt_color != play.attrs.felt_color
      assert String.match?(main.attrs.background_color, ~r/^#[0-9A-F]{6}$/i)
    end

    test "повторный прогон не создаёт дублей и не трогает существующие строки" do
      rows = Grid.expand(currency: :play_money, only: ["NL1000"])

      first = Grid.seed(rows)
      assert length(first.created) == 5

      second = Grid.seed(rows)
      assert second.created == []
      assert length(second.skipped) == 5
      assert length(CashGames.list_settings()) == 5
    end

    test "--force перезаписывает, но не воскрешает выключенный оператором лимит" do
      rows = Grid.expand(currency: :play_money, only: ["NL1000"])
      Grid.seed(rows)

      [setting | _rest] = CashGames.list_settings()
      {:ok, _disabled} = CashGames.set_enabled(setting, false)

      Grid.seed(rows, force: true)

      refute CashGames.get_setting(setting.id) |> elem(1) |> Map.fetch!(:enabled)
    end
  end

  test "settings_without_rake находит только включённые main-шаблоны с нулём" do
    with_rake =
      setting_fixture(%{currency: :main, rake_percent: 500, rake_cap_by_players: %{"2" => 100}})

    zero = setting_fixture(%{currency: :main, small_blind: 25, big_blind: 50, rake_percent: 0})
    _play = setting_fixture(%{currency: :play_money, rake_percent: 0})

    ids = CashGames.settings_without_rake() |> Enum.map(& &1.id)

    assert zero.id in ids
    refute with_rake.id in ids
  end

  describe "закрытые комнаты" do
    test "create_private_setting выдаёт код и прячет комнату из лобби" do
      setting = private_setting_fixture()

      assert setting.visibility == :private
      refute CashGameSetting.public?(setting)
      assert String.length(setting.code) == CashGameSetting.code_length()
      assert CashGameSetting.valid_code?(setting.code)
    end

    test "публичный шаблон кода не получает" do
      assert %CashGameSetting{code: nil, visibility: :public} = setting_fixture()
    end

    test "закрытая комната разворачивает ровно одну комнату" do
      assert CashGameSetting.room_limit(private_setting_fixture()) == 1
      assert CashGameSetting.room_limit(setting_fixture(%{max_rooms: 7})) == 7
    end

    test "поиск по коду прощает регистр и пробелы" do
      setting = private_setting_fixture()
      code = setting.code

      assert {:ok, found} = CashGames.get_by_code(code)
      assert found.id == setting.id

      assert {:ok, found} = CashGames.get_by_code("  #{String.upcase(code)} ")
      assert found.id == setting.id
    end

    test "мусор вместо кода не доходит до базы" do
      assert {:error, :not_found} = CashGames.get_by_code("не код")
      assert {:error, :not_found} = CashGames.get_by_code("abc")
      assert {:error, :not_found} = CashGames.get_by_code(nil)
      assert {:error, :not_found} = CashGames.get_by_code(42)
    end

    test "выключенная комната по коду не находится" do
      setting = private_setting_fixture()
      {:ok, _disabled} = CashGames.set_enabled(setting, false)

      assert {:error, :not_found} = CashGames.get_by_code(setting.code)
    end

    test "код уникален — это гарантия базы, а не проверки перед вставкой" do
      setting = private_setting_fixture()

      assert {:error, changeset} =
               CashGames.create_setting(
                 valid_setting_attrs(%{small_blind: 25, big_blind: 50, code: setting.code})
               )

      assert %{code: [_message]} = errors_on(changeset)
    end

    test "закрытая комната на тех же блайндах, что и публичный лимит, — не дубль" do
      attrs = %{small_blind: 5, big_blind: 10, max_players: 6}

      public = setting_fixture(attrs)
      private = private_setting_fixture(attrs)

      assert public.id != private.id
      assert public.code == nil
      assert private.code != nil
    end

    test "код не принимает форму вне алфавита" do
      assert {:error, changeset} =
               CashGames.create_setting(valid_setting_attrs(%{code: "ABC!23"}))

      assert %{code: [_message]} = errors_on(changeset)
    end
  end

  describe "Short Deck" do
    test "анте-стол создаётся без блайндов" do
      {:ok, setting} =
        CashGames.create_setting(
          valid_setting_attrs(%{game_type: :short_deck, small_blind: 0, big_blind: 0, ante: 10})
        )

      assert setting.game_type == :short_deck
      assert CashGameSetting.bet_unit(setting) == 10
      assert CashGameSetting.structure(setting) == BettingStructure.ButtonAnte
    end

    test "анте-стол с блайндами не создаётся" do
      {:error, changeset} =
        CashGames.create_setting(
          valid_setting_attrs(%{game_type: :short_deck, small_blind: 5, big_blind: 10, ante: 10})
        )

      assert %{small_blind: [_message], big_blind: [_other]} = errors_on(changeset)
    end

    test "анте-стол без анте не создаётся" do
      {:error, changeset} =
        CashGames.create_setting(
          valid_setting_attrs(%{game_type: :short_deck, small_blind: 0, big_blind: 0, ante: 0})
        )

      assert %{ante: [_message]} = errors_on(changeset)
    end

    test "блайндовый стол без блайндов не создаётся" do
      {:error, changeset} =
        CashGames.create_setting(
          valid_setting_attrs(%{game_type: :texas_holdem, small_blind: 0, big_blind: 0, ante: 5})
        )

      assert %{small_blind: [_message]} = errors_on(changeset)
    end

    test "бай-ин анте-стола считается в анте" do
      {:ok, setting} =
        CashGames.create_setting(
          valid_setting_attrs(%{
            game_type: :short_deck,
            small_blind: 0,
            big_blind: 0,
            ante: 10,
            min_buy_in: 40,
            max_buy_in: 100
          })
        )

      assert CashGameSetting.min_buy_in_chips(setting) == 400
      assert CashGameSetting.max_buy_in_chips(setting) == 1_000
    end
  end

  defp named(name, game_type, max_players) do
    CashGameSetting.display_name(%CashGameSetting{
      name: name,
      game_type: game_type,
      max_players: max_players
    })
  end
end
