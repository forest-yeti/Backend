defmodule BlockPoker.Repo.Migrations.AddCashGameBombPot do
  use Ecto.Migration

  def change do
    # Бомб-пот: шанс на раздачу без префлопа и размер взноса за неё.
    #
    # Шанс — целое в десятитысячных (`Engine.BombPot.scale/0`): 500 = 5%,
    # 10_000 = каждая раздача, 0 (дефолт) = механики за столом нет. Дроби
    # в колонке нет намеренно — по тому же правилу, что и у денег: `0.1`
    # после round-trip через БД и JSON не обязано остаться тем же числом.
    #
    # Взнос — в номиналах стола, как и бай-ин: «два номинала» переживает
    # смену лимита, «двадцать фишек» — нет.
    alter table(:cash_game_settings) do
      add :bomb_pot_chance, :integer, null: false, default: 0
      add :bomb_pot_ante, :integer, null: false, default: 2
    end
  end
end
