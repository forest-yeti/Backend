defmodule BlockPoker.CashGames do
  @moduledoc """
  Контекст шаблонов кэш-игры.

  Пишут в контекст трое: `mix cash_game.seed` при первичном наполнении,
  оператор из `iex` и панель администратора через `Admin.Grids`.

  Удаления шаблона нет вовсе: на строку ссылается история раздач. Из сетки
  лимит убирается двумя разными способами, и путать их нельзя. `enabled =
  false` — «сегодня не раздаём», строка остаётся в списке оператора и
  возвращается одним переключателем. `archived_at` — «этого лимита в руме
  больше нет»: он исчезает и из витрины, и из обычного списка панели.
  """

  import Ecto.Query

  alias BlockPoker.CashGames.CashGameSetting
  alias BlockPoker.Repo

  @typedoc """
  `archived: false` — только живые шаблоны (умолчание), `true` — только
  снятые, `nil` — и те и другие. Списком по умолчанию пользуется `Lobby`,
  и снятый шаблон обязан из него пропасть: тогда его комнаты уходят
  в drain сами, по общему правилу «шаблона нет — комнат нет».
  """
  @type filter :: [archived: boolean() | nil]

  @spec list_settings(filter()) :: [CashGameSetting.t()]
  def list_settings(filter \\ []) do
    CashGameSetting
    |> filter_archived(Keyword.get(filter, :archived, false))
    |> order_by(asc: :sort_order, asc: :small_blind, asc: :max_players)
    |> Repo.all()
  end

  @spec list_enabled_settings() :: [CashGameSetting.t()]
  def list_enabled_settings do
    CashGameSetting
    |> where(enabled: true)
    |> filter_archived(false)
    |> order_by(asc: :sort_order, asc: :small_blind, asc: :max_players)
    |> Repo.all()
  end

  @doc false
  @spec filter_archived(Ecto.Queryable.t(), boolean() | nil) :: Ecto.Queryable.t()
  def filter_archived(query, nil), do: query
  def filter_archived(query, false), do: where(query, [s], is_nil(s.archived_at))
  def filter_archived(query, true), do: where(query, [s], not is_nil(s.archived_at))

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

  Код входа — часть ключа, и это не деталь: в UNIQUE он входит как
  `code_key = IFNULL(code, '')`, потому что домашняя игра на тех же
  блайндах, что и публичный лимит, — законная строка, а не дубль
  (миграция `add_cash_game_code`). Искать без него значит спрашивать
  «строки с такими блайндами», а на этот вопрос у базы законно бывает
  несколько ответов: один публичный лимит и сколько угодно закрытых
  комнат поверх него. Сид от такого падал бы `MultipleResultsError` —
  и падал ровно там, где оператор завёл приватку на сеточных лимитах.
  """
  @spec get_by_natural_key(map()) :: CashGameSetting.t() | nil
  def get_by_natural_key(attrs) do
    CashGameSetting
    |> where(
      game_type: ^attrs.game_type,
      currency: ^attrs.currency,
      small_blind: ^attrs.small_blind,
      big_blind: ^attrs.big_blind,
      ante: ^attrs.ante,
      max_players: ^attrs.max_players
    )
    |> by_code(Map.get(attrs, :code))
    |> Repo.one()
  end

  # `code: nil` в keyword-фильтр Ecto не пускает (сравнение с NULL небезопасно),
  # поэтому ветка отделена явно: у сеточных шаблонов кода нет вовсе.
  defp by_code(query, nil), do: where(query, [c], is_nil(c.code))
  defp by_code(query, code), do: where(query, [c], c.code == ^code)

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
    # Ключи приводятся к строкам до подстановки своих: с провода приходит
    # карта со строковыми ключами, и смешанную Ecto не принимает вовсе.
    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.put("visibility", "private")
      |> Map.put("code", CashGameSetting.generate_code())

    case create_setting(attrs) do
      {:error, changeset} when attempts > 0 ->
        if Keyword.has_key?(changeset.errors, :code) do
          create_private_setting(Map.delete(attrs, "code"), attempts - 1)
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

  @doc """
  Снятие шаблона с сетки. Строка остаётся ради истории, но выпадает
  и из витрины, и из пула: `enabled` гасится **вместе** с отметкой, иначе
  возвращённый из архива лимит молча начал бы раздавать сам.
  """
  @spec archive_setting(CashGameSetting.t()) ::
          {:ok, CashGameSetting.t()} | {:error, Ecto.Changeset.t()}
  def archive_setting(%CashGameSetting{} = setting) do
    setting
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now(), enabled: false)
    |> Repo.update()
  end

  @doc """
  Возврат из архива. Шаблон возвращается **выключенным**: оператор сначала
  смотрит, что в нём написано, и только потом пускает на него людей.
  """
  @spec restore_setting(CashGameSetting.t()) ::
          {:ok, CashGameSetting.t()} | {:error, Ecto.Changeset.t()}
  def restore_setting(%CashGameSetting{} = setting) do
    setting
    |> Ecto.Changeset.change(archived_at: nil, enabled: false)
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
