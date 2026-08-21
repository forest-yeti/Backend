defmodule BlockPoker.Repo.Migrations.GoldSitNGoVisuals do
  use Ecto.Migration

  @moduledoc """
  Золотой антураж турнирных столов.

  Цвет — способ отличить режим с одного взгляда: кэш зелёный, Sit & Go
  золотой. Поэтому это дефолт **режима**, а не украшение отдельных строк:
  меняются и умолчания колонок, и уже заведённые шаблоны.

  Оператор по-прежнему волен перекрасить любой стол — правка идёт в тех же
  полях, что и у кэша.
  """

  # Приглушённое антикварное золото, а не чистый `#FFD700`: на ярком фоне
  # белые карты и светлые фишки теряются, и стол становится нечитаемым.
  @felt "#9A7A2E"
  # Фон — глубокий тёплый почти-чёрный: тот же приём, что и у кэша, где
  # фон это очень тёмная версия цвета сукна.
  @background "#151006"

  @old_felt "#1F6F4A"
  @old_background "#10241C"

  def up do
    alter table(:sit_n_go_settings) do
      modify :felt_color, :string, size: 9, null: false, default: @felt
      modify :background_color, :string, size: 9, null: false, default: @background
    end

    # Перекрашиваются только столы, оставшиеся в зелёном умолчании: стол,
    # который оператор уже настроил под себя, миграция не трогает.
    execute """
    UPDATE sit_n_go_settings
       SET felt_color = '#{@felt}'
     WHERE felt_color = '#{@old_felt}'
    """

    execute """
    UPDATE sit_n_go_settings
       SET background_color = '#{@background}'
     WHERE background_color = '#{@old_background}'
    """
  end

  def down do
    alter table(:sit_n_go_settings) do
      modify :felt_color, :string, size: 9, null: false, default: @old_felt
      modify :background_color, :string, size: 9, null: false, default: @old_background
    end

    execute """
    UPDATE sit_n_go_settings
       SET felt_color = '#{@old_felt}'
     WHERE felt_color = '#{@felt}'
    """

    execute """
    UPDATE sit_n_go_settings
       SET background_color = '#{@old_background}'
     WHERE background_color = '#{@background}'
    """
  end
end
