defmodule BlockPoker.Banners do
  @moduledoc """
  Баннеры: что показывается в конкретном месте интерфейса.

  Контекст закрывает две задачи, как и `ClientReleases`:

    * **клиентскую** — `get/1` для `GET /api/banners/:place`. Ручка
      публичная: баннер видят и до логина (`OnRunApplication` показывается
      ровно на запуске приложения, когда токена ещё нет);
    * **административную** — `list/0`, `put/2`, `delete/2`. Эти зовутся
      только через `BlockPoker.Admin`, который проверяет роль.

  **Место — ключ, а не идентификатор строки.** Одно место — один баннер,
  и правка места это upsert, а не «создать ещё один». Так панели не нужно
  различать создание и редактирование, а клиенту — выбирать из нескольких
  кандидатов на один блок.

  Картинка заменяется вместе с записью: новый файл ложится на диск до
  транзакции, старый удаляется после её успеха. Порядок именно такой,
  потому что ошибка записи в БД должна оставлять баннер рабочим — со
  старой картинкой, — а не показывать битую ссылку.
  """

  import Ecto.Query

  alias BlockPoker.Admin.{Audit, Context}
  alias BlockPoker.Banners.{Banner, Storage}
  alias BlockPoker.Repo
  alias Ecto.Multi

  @type view :: %{
          place: String.t(),
          image: String.t(),
          helper: String.t() | nil,
          link: String.t() | nil
        }

  @doc "Все места показа. Панель берёт список отсюда, а не держит свой."
  @spec places() :: [String.t()]
  defdelegate places(), to: Banner

  # --- клиентская часть -----------------------------------------------------

  @doc """
  Баннер места или `{:error, :not_found}`.

  Незнакомое место — тоже `:not_found`, а не отдельный код: для клиента
  «этого баннера нет» и «такого места не бывает» приводят к одному
  действию — не рисовать блок.
  """
  @spec get(term()) :: {:ok, view()} | {:error, :not_found}
  def get(place) when is_binary(place) do
    if Banner.place?(place) do
      case Repo.get_by(Banner, place: place) do
        nil -> {:error, :not_found}
        banner -> {:ok, view(banner)}
      end
    else
      {:error, :not_found}
    end
  end

  def get(_place), do: {:error, :not_found}

  # --- административная часть -----------------------------------------------

  @doc """
  Всё, что нужно экрану баннеров: список мест и что в каждом стоит.

  Отдаются **все** места, включая пустые: экран показывает слоты, а не
  строки таблицы, — иначе админ не узнает, что место вообще существует,
  пока туда что-нибудь не положат.
  """
  @spec list() :: %{places: [String.t()], items: [map()]}
  def list do
    filled =
      Banner
      |> preload(:updated_by)
      |> Repo.all()
      |> Map.new(&{&1.place, &1})

    %{
      places: places(),
      items: Enum.map(places(), &slot(&1, filled[&1]))
    }
  end

  @doc """
  Создание или замена баннера места.

  `attrs` содержит место, тексты и — необязательно — путь к временному
  файлу новой картинки. Картинки нет и баннера ещё не было — это ошибка:
  баннер без изображения показывать нечем. Картинки нет, а баннер был —
  меняются только тексты.
  """
  @spec put(Context.t(), map()) :: {:ok, map()} | {:error, atom() | Ecto.Changeset.t()}
  def put(%Context{} = ctx, attrs) do
    place = to_string(attrs[:place] || "")
    existing = Repo.get_by(Banner, place: place)

    uploaded? = is_binary(attrs[:path])

    with :ok <- ensure_place(place),
         {:ok, image_file} <- resolve_image(attrs[:path], place, existing) do
      changeset =
        Banner.changeset(existing || %Banner{}, %{
          place: place,
          image_file: image_file,
          helper: attrs[:helper],
          link: attrs[:link],
          updated_by_id: ctx.admin_id
        })

      Multi.new()
      |> Multi.insert_or_update(:banner, changeset)
      |> audit_step(ctx, :banner_update, fn %{banner: banner} ->
        %{place: banner.place, image_file: banner.image_file, link: banner.link}
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{banner: banner}} ->
          # Старая картинка убирается только после успеха: до него она —
          # единственная рабочая.
          if uploaded? and existing, do: Storage.delete(existing.image_file)
          {:ok, slot(banner.place, banner)}

        {:error, _step, reason, _changes} ->
          if uploaded?, do: Storage.delete(image_file)
          {:error, failure(reason)}
      end
    end
  end

  @doc "Снятие баннера с места. Файл картинки удаляется вместе с записью."
  @spec delete(Context.t(), String.t()) :: :ok | {:error, atom()}
  def delete(%Context{} = ctx, place) do
    with :ok <- ensure_place(place),
         {:ok, banner} <- fetch(place) do
      Multi.new()
      |> Multi.delete(:banner, banner)
      |> audit_step(ctx, :banner_delete, %{place: banner.place, image_file: banner.image_file})
      |> Repo.transaction()
      |> case do
        {:ok, _changes} ->
          Storage.delete(banner.image_file)
          :ok

        {:error, _step, reason, _changes} ->
          {:error, failure(reason)}
      end
    end
  end

  # --- внутреннее -----------------------------------------------------------

  # То, что уходит клиенту: место, готовый адрес картинки и два текста.
  # Имя файла на диске наружу не отдаётся — снаружи существует только URL.
  defp view(%Banner{} = banner) do
    %{
      place: banner.place,
      image: Storage.url(banner.image_file),
      helper: banner.helper,
      link: banner.link
    }
  end

  # Карточка места для панели: пустой слот — это тоже строка списка.
  defp slot(place, nil) do
    %{place: place, image: nil, helper: nil, link: nil, updated_at: nil, updated_by: nil}
  end

  defp slot(place, %Banner{} = banner) do
    place
    |> slot(nil)
    |> Map.merge(view(banner))
    |> Map.merge(%{
      updated_at: banner.updated_at,
      updated_by: updated_by(banner)
    })
  end

  defp updated_by(%Banner{updated_by: %{name: name}}), do: name
  defp updated_by(_banner), do: nil

  defp resolve_image(path, place, _existing) when is_binary(path), do: Storage.store(path, place)
  defp resolve_image(_absent, _place, %Banner{image_file: file}), do: {:ok, file}
  defp resolve_image(_absent, _place, nil), do: {:error, :banner_image_required}

  defp ensure_place(place) do
    if Banner.place?(place), do: :ok, else: {:error, :invalid_place}
  end

  defp fetch(place) do
    case Repo.get_by(Banner, place: place) do
      nil -> {:error, :not_found}
      banner -> {:ok, banner}
    end
  end

  defp audit_step(multi, ctx, action, attrs) do
    Audit.step(multi, :audit, ctx, fn changes ->
      banner = changes[:banner]

      %{
        action: action,
        subject_type: :banner,
        subject_id: banner && banner.place,
        meta: if(is_function(attrs, 1), do: attrs.(changes), else: attrs)
      }
    end)
  end

  defp failure(%Ecto.Changeset{} = changeset), do: changeset
  defp failure(reason) when is_atom(reason), do: reason
  defp failure(_reason), do: :internal_error
end
