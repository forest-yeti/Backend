defmodule BlockPoker.CashGames do
  @moduledoc """
  Контекст шаблонов кэш-игры.

  Приложение шаблоны в основном **читает**: правятся они напрямую в БД (§8
  задачи 3). Запись здесь нужна двум клиентам — `mix cash_game.seed` при
  первичном наполнении и оператору из `iex`; HTTP-админки нет и не планируется.

  Удаления шаблона нет вовсе: на строку ссылается история раздач. Лимит
  убирается из лобби через `enabled = false`.
  """

  import Ecto.Query

  alias BlockPoker.CashGames.CashGameSetting
  alias BlockPoker.Repo

  @spec list_settings() :: [CashGameSetting.t()]
  def list_settings do
    CashGameSetting
    |> order_by(asc: :sort_order, asc: :small_blind, asc: :max_players)
    |> Repo.all()
  end

  @spec list_enabled_settings() :: [CashGameSetting.t()]
  def list_enabled_settings do
    CashGameSetting
    |> where(enabled: true)
    |> order_by(asc: :sort_order, asc: :small_blind, asc: :max_players)
    |> Repo.all()
  end

  @spec get_setting(Ecto.UUID.t()) :: {:ok, CashGameSetting.t()} | {:error, :not_found}
  def get_setting(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> fetch_setting(id)
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Поиск по естественному ключу — тому же, на котором стоит UNIQUE.
  Нужен сиду: «такая строка уже есть» определяется ключом, а не именем.
  """
  @spec get_by_natural_key(map()) :: CashGameSetting.t() | nil
  def get_by_natural_key(attrs) do
    Repo.get_by(CashGameSetting,
      game_type: attrs.game_type,
      currency: attrs.currency,
      small_blind: attrs.small_blind,
      big_blind: attrs.big_blind,
      ante: attrs.ante,
      max_players: attrs.max_players
    )
  end

  @doc """
  Поиск закрытой комнаты по коду входа. Регистр и пробелы игроку прощаются,
  выключенный шаблон не находится: код погашенной комнаты — тот же «нет».
  """
  @spec get_by_code(term()) :: {:ok, CashGameSetting.t()} | {:error, :not_found}
  def get_by_code(code) do
    if CashGameSetting.valid_code?(code) do
      normalized = CashGameSetting.normalize_code(code)

      case Repo.get_by(CashGameSetting, code: normalized, enabled: true) do
        nil -> {:error, :not_found}
        setting -> {:ok, setting}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Создание закрытой комнаты: код выдаётся сервером, а не оператором.
  Столкновение кодов ловит UNIQUE-индекс — тогда берётся следующий.
  """
  @spec create_private_setting(map(), non_neg_integer()) ::
          {:ok, CashGameSetting.t()} | {:error, Ecto.Changeset.t()}
  def create_private_setting(attrs, attempts \\ 5) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put(:visibility, :private)
      |> Map.put(:code, CashGameSetting.generate_code())

    case create_setting(attrs) do
      {:error, changeset} when attempts > 0 ->
        if Keyword.has_key?(changeset.errors, :code) do
          create_private_setting(Map.delete(attrs, :code), attempts - 1)
        else
          {:error, changeset}
        end

      result ->
        result
    end
  end

  @spec create_setting(map()) :: {:ok, CashGameSetting.t()} | {:error, Ecto.Changeset.t()}
  def create_setting(attrs) do
    %CashGameSetting{}
    |> CashGameSetting.changeset(attrs)
    |> Repo.insert()
  end

  @spec update_setting(CashGameSetting.t(), map()) ::
          {:ok, CashGameSetting.t()} | {:error, Ecto.Changeset.t()}
  def update_setting(%CashGameSetting{} = setting, attrs) do
    setting
    |> CashGameSetting.changeset(attrs)
    |> Repo.update()
  end

  @spec set_enabled(CashGameSetting.t(), boolean()) ::
          {:ok, CashGameSetting.t()} | {:error, Ecto.Changeset.t()}
  def set_enabled(%CashGameSetting{} = setting, enabled?) when is_boolean(enabled?) do
    update_setting(setting, %{enabled: enabled?})
  end

  @doc """
  Шаблоны на реальные деньги с нулевым рейком.

  Нулевой рейк — законное состояние сразу после сида, но забытая настройка
  стоит руму всей выручки, поэтому `Lobby` при старте о них предупреждает.
  """
  @spec settings_without_rake() :: [CashGameSetting.t()]
  def settings_without_rake do
    CashGameSetting
    |> where(enabled: true, currency: :main, rake_percent: 0)
    |> Repo.all()
  end

  defp fetch_setting(id) do
    case Repo.get(CashGameSetting, id) do
      nil -> {:error, :not_found}
      setting -> {:ok, setting}
    end
  end
end
