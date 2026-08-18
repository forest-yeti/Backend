defmodule BlockPoker.CashGamesFixtures do
  @moduledoc """
  Фабрики шаблонов кэш-игры. Через публичный API контекста, а не прямыми
  `Repo.insert` (§11 CLAUDE.md).

  `build_setting/1` собирает структуру **без** похода в БД — это нужно тестам
  уровня 2: комната копирует настройки себе при запуске и в БД за ними
  не ходит, поэтому проверять её можно без Sandbox.
  """

  alias BlockPoker.CashGames
  alias BlockPoker.CashGames.CashGameSetting

  def valid_setting_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "Тестовый лимит",
        game_type: :texas_holdem,
        currency: :play_money,
        small_blind: 5,
        big_blind: 10,
        ante: 0,
        max_players: 6,
        min_buy_in: 40,
        max_buy_in: 100
      },
      Map.new(overrides)
    )
  end

  @doc "Шаблон в памяти: с уникальным id, но без записи в БД."
  def build_setting(overrides \\ %{}) do
    attrs = valid_setting_attrs(overrides)
    struct!(%CashGameSetting{id: Ecto.UUID.generate()}, attrs)
  end

  @doc """
  Шаблон в БД. Блайнды по умолчанию фиксированные (5/10): естественный ключ
  уникален, но каждый тест живёт в своей откатываемой транзакции, поэтому
  столкнуться могут только два шаблона внутри одного теста — там блайнды
  задаются явно.
  """
  def setting_fixture(overrides \\ %{}) do
    {:ok, setting} = overrides |> valid_setting_attrs() |> CashGames.create_setting()
    setting
  end
end
