defmodule BlockPoker.ClientReleases do
  @moduledoc """
  Сборки клиентского приложения: что залито, что опубликовано, что
  считать актуальным и что — устаревшим.

  Контекст закрывает две разные задачи, и это осознанно:

    * **игровую** — `check/1` на каждом handshake и `info/0` для ручки
      версии. Обе читают кэш `Feed`, в БД не ходят;
    * **административную** — загрузка, публикация и удаление сборок.
      Эти зовутся только через `BlockPoker.Admin`, который проверяет роль.

  Версия клиента (semver `1.0.1`) — это версия сборки Electron. Она
  намеренно отделена от `Socket.Protocol.Version`: та описывает формат
  сообщений и меняется редко, эта растёт на каждом релизе.

  **Загрузка и публикация разделены.** Залитая сборка лежит черновиком:
  файл на диске есть, скачать и проверить его можно, но в `latest.yml` он
  не попадает и для клиентов не существует. Публикация — отдельное
  действие, и только она переписывает фид. Так залитый по ошибке файл не
  уводит на битую сборку весь рум в момент выбора файла в диалоге.
  """

  import Ecto.Query

  alias BlockPoker.Admin.{Audit, Context}
  alias BlockPoker.ClientReleases.{Feed, Release, Storage}
  alias BlockPoker.Repo
  alias Ecto.Multi

  @type info :: %{current: String.t(), minimum: String.t(), feed_url: String.t() | nil}

  # --- игровая часть --------------------------------------------------------

  @doc """
  Что клиенту нужно знать об обновлениях: обе границы версий и адрес
  фида, с которого `electron-updater` качает сборку.
  """
  @spec info() :: info()
  def info, do: Map.put(Feed.state(), :feed_url, feed_url())

  @spec current() :: String.t()
  def current, do: Feed.state().current

  @spec minimum() :: String.t()
  def minimum, do: Feed.state().minimum

  @doc """
  Адрес фида обновлений. Отдаётся клиенту, а не зашивается в сборку:
  иначе переезд раздачи на другой хост потребовал бы релиза того самого
  клиента, который этим релизом и обновляют.
  """
  @spec feed_url() :: String.t() | nil
  def feed_url, do: Application.get_env(:block_poker, :client_release, [])[:feed_url]

  @doc """
  Пускаем ли эту сборку в игру.

  Версия не передана — считаем нулевой: клиент, который про версии не
  знает, собран до появления этой проверки, и он ровно тот, кого минимум
  отсекает. Нераспознанная строка трактуется так же — иначе гейт
  обходился бы мусором.
  """
  @spec check(String.t() | nil) :: :ok | {:error, :client_too_old}
  def check(client_vsn) do
    if below?(client_vsn, minimum()), do: {:error, :client_too_old}, else: :ok
  end

  @doc "Есть ли сборка новее той, что у клиента."
  @spec outdated?(String.t() | nil) :: boolean()
  def outdated?(client_vsn), do: below?(client_vsn, current())

  @doc "Перечитывает границы версий из БД. Зовётся при старте ноды."
  @spec refresh() :: :ok
  def refresh do
    Feed.refresh()
    :ok
  end

  # --- административная часть -----------------------------------------------

  @doc """
  Всё, что нужно экрану сборок: список (свежие первыми) и границы версий.

  Границы отдаются вместе со списком, а не вычисляются панелью по нему:
  «актуальная — последняя опубликованная», «минимум не выше актуальной» —
  доменные правила, и считать их в двух местах значит рано или поздно
  разойтись с тем, что видит клиент.
  """
  @spec list() :: map()
  def list do
    releases =
      Release
      |> order_by([r], desc: r.inserted_at)
      |> preload(:uploaded_by)
      |> Repo.all()
      |> Enum.map(&decorate/1)

    Map.put(info(), :items, releases)
  end

  @doc """
  Приём загруженной сборки.

  Файл кладётся на диск **до** записи в БД: считать sha512 и размер можно
  только с готового файла, а они входят в саму запись. Если запись не
  прошла — файл убирается, иначе каталог копил бы сборки, которых нет ни
  в одном списке.
  """
  @spec upload(Context.t(), map()) :: {:ok, map()} | {:error, atom() | Ecto.Changeset.t()}
  def upload(%Context{} = ctx, %{path: path, original_name: original_name} = attrs) do
    version = to_string(attrs[:version] || "")
    file_name = file_name(version, original_name)

    with :ok <- ensure_version(version),
         :ok <- ensure_new_version(version),
         {:ok, %{byte_size: size, sha512: sha512}} <- Storage.store(path, file_name) do
      Multi.new()
      |> Multi.insert(
        :release,
        Release.changeset(%Release{}, %{
          version: version,
          file_name: file_name,
          byte_size: size,
          sha512: sha512,
          mandatory: !!attrs[:mandatory],
          notes: attrs[:notes],
          uploaded_by_id: ctx.admin_id
        })
      )
      |> audit_step(ctx, :client_release_upload, fn %{release: release} ->
        %{file_name: release.file_name, byte_size: release.byte_size, version: release.version}
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{release: release}} ->
          {:ok, decorate(release)}

        {:error, _step, reason, _changes} ->
          Storage.delete(file_name)
          {:error, failure(reason)}
      end
    end
  end

  @doc """
  Публикация: сборка становится актуальной для всех клиентов.

  Фид переписывается **внутри транзакции**: если `latest.yml` записать не
  удалось, публикации не было и в базе — иначе панель показывала бы
  опубликованный релиз, которого клиенты не видят.
  """
  @spec publish(Context.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, atom()}
  def publish(%Context{} = ctx, id) do
    with {:ok, release} <- fetch(id),
         :ok <- ensure_file_present(release) do
      Multi.new()
      |> Multi.update(:release, Ecto.Changeset.change(release, published_at: DateTime.utc_now()))
      |> Multi.run(:feed, fn _repo, %{release: published} ->
        case Storage.write_feed(published) do
          :ok -> {:ok, :written}
          {:error, reason} -> {:error, reason}
        end
      end)
      |> audit_step(ctx, :client_release_publish, fn %{release: published} ->
        %{version: published.version, mandatory: published.mandatory}
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{release: published}} ->
          Feed.refresh()
          {:ok, decorate(published)}

        {:error, _step, reason, _changes} ->
          {:error, failure(reason)}
      end
    end
  end

  @doc """
  Удаление сборки.

  Удалить можно только черновик. Опубликованный релиз остаётся навсегда:
  на него ссылается `latest.yml`, и у части игроков он прямо сейчас
  качается — стереть файл из-под них значит оборвать обновление на
  середине.
  """
  @spec delete(Context.t(), Ecto.UUID.t()) :: :ok | {:error, atom()}
  def delete(%Context{} = ctx, id) do
    with {:ok, release} <- fetch(id),
         :ok <- ensure_draft(release) do
      Multi.new()
      |> Multi.delete(:release, release)
      |> audit_step(ctx, :client_release_delete, %{
        version: release.version,
        file_name: release.file_name
      })
      |> Repo.transaction()
      |> case do
        {:ok, _changes} ->
          Storage.delete(release.file_name)
          :ok

        {:error, _step, reason, _changes} ->
          {:error, failure(reason)}
      end
    end
  end

  # --- внутреннее -----------------------------------------------------------

  defp audit_step(multi, ctx, action, attrs) do
    Audit.step(multi, :audit, ctx, fn changes ->
      release = changes[:release]

      %{
        action: action,
        subject_type: :client_release,
        subject_id: release && release.id,
        meta: if(is_function(attrs, 1), do: attrs.(changes), else: attrs)
      }
    end)
  end

  # Идентификатор приходит из URL, то есть может быть чем угодно.
  # `Repo.get/2` на не-UUID падает `CastError`, поэтому разбираем сами.
  defp fetch(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Release{} = release <- Repo.get(Release, uuid) do
      {:ok, release}
    else
      _missing -> {:error, :not_found}
    end
  end

  defp ensure_draft(%Release{published_at: nil}), do: :ok
  defp ensure_draft(%Release{}), do: {:error, :release_published}

  # Публиковать запись, файла которой на диске нет, нельзя: фид уведёт
  # каждого клиента на 404 и сломает обновление у всех разом.
  defp ensure_file_present(%Release{file_name: file_name}) do
    if Storage.exists?(file_name), do: :ok, else: {:error, :release_file_missing}
  end

  defp ensure_version(version) do
    case Version.parse(version) do
      {:ok, _parsed} -> :ok
      :error -> {:error, :invalid_version}
    end
  end

  defp ensure_new_version(version) do
    if Repo.exists?(from r in Release, where: r.version == ^version) do
      {:error, :version_exists}
    else
      :ok
    end
  end

  # Имя файла собирается сервером, а не берётся с провода: в нём приходит
  # то, что выбрал администратор в диалоге, включая пробелы, кириллицу и
  # `../`. Версия впереди делает имя уникальным и читаемым в каталоге.
  defp file_name(version, original_name) do
    base =
      original_name
      |> to_string()
      |> Path.basename()
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "_")
      |> String.trim("_")
      |> String.slice(0, 120)

    base = if base in ["", ".", ".."], do: "setup.exe", else: base

    "#{String.replace(version, ~r/[^A-Za-z0-9._-]/, "_")}_#{base}"
  end

  defp decorate(%Release{} = release) do
    %{
      id: release.id,
      version: release.version,
      file_name: release.file_name,
      byte_size: release.byte_size,
      sha512: release.sha512,
      mandatory: release.mandatory,
      published_at: release.published_at,
      notes: release.notes,
      inserted_at: release.inserted_at,
      file_present: Storage.exists?(release.file_name),
      uploaded_by: uploaded_by(release)
    }
  end

  # Свежевставленная строка ассоциацию не подгружает, и это не повод
  # ходить за ней в базу: кто загрузил — знает список, а не ответ на саму
  # загрузку.
  defp uploaded_by(%Release{uploaded_by: %Ecto.Association.NotLoaded{}}), do: nil
  defp uploaded_by(%Release{uploaded_by: %{} = admin}), do: %{id: admin.id, name: admin.name}
  defp uploaded_by(%Release{}), do: nil

  defp below?(client_vsn, boundary) do
    case {parse(client_vsn), parse(boundary)} do
      # Граница не настроена или задана мусором — не отсекаем никого:
      # ошибка конфигурации не должна выглядеть как массовый бан клиентов.
      {_client, :error} -> false
      {:error, _boundary} -> true
      {{:ok, client}, {:ok, limit}} -> Version.compare(client, limit) == :lt
    end
  end

  defp parse(nil), do: {:ok, Version.parse!("0.0.0")}
  defp parse(vsn) when is_binary(vsn), do: Version.parse(vsn)
  defp parse(_vsn), do: :error

  # Changeset проходит наружу как есть: панель показывает, какое поле не
  # прошло валидацию, а не «внутренняя ошибка».
  defp failure(%Ecto.Changeset{} = changeset), do: changeset
  defp failure(reason) when is_atom(reason), do: reason
  defp failure(_reason), do: :internal_error
end
