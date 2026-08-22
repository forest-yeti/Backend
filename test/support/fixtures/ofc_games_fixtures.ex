defmodule BlockPoker.OfcGamesFixtures do
  @moduledoc """
  Фабрики шаблонов китайского покера. Через публичный API контекста, а не
  прямыми `Repo.insert` (§11 CLAUDE.md).

  `build_setting/1` собирает структуру **без** похода в БД: комната копирует
  настройки себе при запуске и в базу за ними не ходит, поэтому тесты уровня
  2 обходятся без Sandbox.
  """

  alias BlockPoker.OfcGames
  alias BlockPoker.OfcGames.OfcSetting

  def valid_setting_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "Тестовый OFC",
        game_type: :texas_holdem,
        currency: :play_money,
        point_value: 10,
        max_players: 3,
        min_buy_in: 50,
        max_buy_in: 200
      },
      Map.new(overrides)
    )
  end

  @doc "Шаблон в памяти: с уникальным id, но без записи в БД."
  def build_setting(overrides \\ %{}) do
    attrs = valid_setting_attrs(overrides)
    struct!(%OfcSetting{id: Ecto.UUID.generate()}, attrs)
  end

  @doc "Шаблон в БД."
  def setting_fixture(overrides \\ %{}) do
    {:ok, setting} = overrides |> valid_setting_attrs() |> OfcGames.create_setting()
    setting
  end
end
