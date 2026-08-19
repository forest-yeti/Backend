defmodule BlockPoker.Repo.Migrations.RelaxCashGameBlindsCheck do
  use Ecto.Migration

  # Прежний CHECK требовал блайндов у любого стола: `small_blind > 0`.
  # На анте-столе (Short Deck) блайндов нет вовсе, и такой стол в БД
  # не помещался.
  #
  # Условный CHECK по `game_type` писать не стали: правило «какие номиналы
  # обязан заполнить шаблон» принадлежит структуре ставок и живёт в
  # `CashGameSetting.changeset/2` — бизнес-правилам в БД места нет (§6
  # CLAUDE.md). В базе остаётся только то, что она обязана гарантировать
  # независимо от кода: неотрицательность и порядок номиналов.
  def up do
    drop constraint(:cash_game_settings, :cash_game_settings_blinds)

    create constraint(:cash_game_settings, :cash_game_settings_blinds,
             check: "small_blind >= 0 AND big_blind >= small_blind AND ante >= 0"
           )
  end

  def down do
    drop constraint(:cash_game_settings, :cash_game_settings_blinds)

    create constraint(:cash_game_settings, :cash_game_settings_blinds,
             check: "big_blind > small_blind AND small_blind > 0 AND ante >= 0"
           )
  end
end
