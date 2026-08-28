defmodule BlockPoker.OfcGames do
  @moduledoc """
  Контекст шаблонов китайского покера.

  Устроен так же, как `BlockPoker.CashGames`, и по тем же причинам:
  приложение шаблоны в основном **читает**, а пишут сид, оператор из
  `iex` и панель через `Admin.Grids`. Удаления нет — на строку ссылается
  история раздач; из сетки лимит убирается либо `enabled = false`
  («сегодня не раздаём»), либо `archived_at` («такого лимита больше нет»).
  """

  import Ecto.Query

  alias BlockPoker.CashGames
  alias BlockPoker.OfcGames.OfcSetting
  alias BlockPoker.Repo

  @typedoc "См. `BlockPoker.CashGames.filter/0` — правило одно на оба контекста."
  @type filter :: [archived: boolean() | nil]

  @spec list_settings(filter()) :: [OfcSetting.t()]
  def list_settings(filter \\ []) do
    OfcSetting
    |> CashGames.filter_archived(Keyword.get(filter, :archived, false))
    |> order_by(asc: :sort_order, asc: :point_value, asc: :max_players)
    |> Repo.all()
  end

  @spec list_enabled_settings() :: [OfcSetting.t()]
  def list_enabled_settings do
    OfcSetting
    |> where(enabled: true)
    |> CashGames.filter_archived(false)
    |> order_by(asc: :sort_order, asc: :point_value, asc: :max_players)
    |> Repo.all()
  end

  @spec get_setting(Ecto.UUID.t()) :: {:ok, OfcSetting.t()} | {:error, :not_found}
  def get_setting(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> fetch_setting(id)
      :error -> {:error, :not_found}
    end
  end

  @doc "Поиск по естественному ключу — тому же, на котором стоит UNIQUE. Нужен сиду."
  @spec get_by_natural_key(map()) :: OfcSetting.t() | nil
  def get_by_natural_key(attrs) do
    OfcSetting
    |> where(
      currency: ^attrs.currency,
      point_value: ^attrs.point_value,
      max_players: ^attrs.max_players
    )
    |> Repo.one()
  end

  @doc "Закрытая комната по коду входа. Код нормализуется до похода в базу."
  @spec get_by_code(term()) :: {:ok, OfcSetting.t()} | {:error, :not_found}
  def get_by_code(code) do
    with true <- OfcSetting.valid_code?(code),
         normalized = OfcSetting.normalize_code(code),
         %OfcSetting{} = setting <- Repo.get_by(OfcSetting, code: normalized, enabled: true) do
      {:ok, setting}
    else
      _other -> {:error, :not_found}
    end
  end

  @doc """
  Закрытая комната: код выдаёт сервер, а не оператор. Столкновение отсекает
  UNIQUE-индекс, поэтому повтор — это ретрай, а не проверка перед вставкой.
  """
  @spec create_private_setting(map(), non_neg_integer()) ::
          {:ok, OfcSetting.t()} | {:error, Ecto.Changeset.t()}
  def create_private_setting(attrs, attempts \\ 5) do
    # Ключи приводятся к строкам до подстановки своих: с провода приходит
    # карта со строковыми ключами, и смешанную Ecto не принимает вовсе.
    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.put("visibility", "private")
      |> Map.put("code", OfcSetting.generate_code())

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

  @spec create_setting(map()) :: {:ok, OfcSetting.t()} | {:error, Ecto.Changeset.t()}
  def create_setting(attrs) do
    %OfcSetting{}
    |> OfcSetting.changeset(attrs)
    |> Repo.insert()
  end

  @spec update_setting(OfcSetting.t(), map()) ::
          {:ok, OfcSetting.t()} | {:error, Ecto.Changeset.t()}
  def update_setting(%OfcSetting{} = setting, attrs) do
    setting
    |> OfcSetting.changeset(attrs)
    |> Repo.update()
  end

  @doc "Снятие шаблона с сетки. См. `BlockPoker.CashGames.archive_setting/1`."
  @spec archive_setting(OfcSetting.t()) :: {:ok, OfcSetting.t()} | {:error, Ecto.Changeset.t()}
  def archive_setting(%OfcSetting{} = setting) do
    setting
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now(), enabled: false)
    |> Repo.update()
  end

  @doc "Возврат из архива — выключенным. См. `BlockPoker.CashGames.restore_setting/1`."
  @spec restore_setting(OfcSetting.t()) :: {:ok, OfcSetting.t()} | {:error, Ecto.Changeset.t()}
  def restore_setting(%OfcSetting{} = setting) do
    setting
    |> Ecto.Changeset.change(archived_at: nil, enabled: false)
    |> Repo.update()
  end

  @spec set_enabled(OfcSetting.t(), boolean()) ::
          {:ok, OfcSetting.t()} | {:error, Ecto.Changeset.t()}
  def set_enabled(%OfcSetting{} = setting, enabled?) when is_boolean(enabled?) do
    setting
    |> Ecto.Changeset.change(enabled: enabled?)
    |> Repo.update()
  end

  defp fetch_setting(id) do
    case Repo.get(OfcSetting, id) do
      nil -> {:error, :not_found}
      setting -> {:ok, setting}
    end
  end
end
