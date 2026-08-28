defmodule BlockPoker.Sounds do
  @moduledoc """
  Звуки администрации: библиотека файлов и их воспроизведение в зале.

  Здесь сходятся две разные по природе вещи, и это намеренно.

    * **Звук — сущность.** Файл загружают один раз, а проигрывают много;
      библиотека переживает рестарт и живёт в таблице `sounds`
      (как `BlockPoker.Banners`).
    * **Воспроизведение — событие.** Оно не хранится ни минуты: у него
      нет состояния, которое кому-то понадобилось бы прочитать позже,
      кроме факта «кто и куда отправил», а факт — это журнал
      (как `BlockPoker.Announcements`).

  Отсюда главное следствие для панели: **остановить уже отправленный
  звук нельзя.** Он ушёл. Кнопки «прекратить» нет, и это не упущение —
  звук длится секунды, а механизм отмены пришлось бы держать в каждом
  клиенте.

  **Адресат — не строка, а цель.** Комната, турнир целиком или весь зал:
  у турнира нет своего стола, его игроки сидят за несколькими, и
  «проиграть в турнире» разворачивается в рассылку по всем его столам.
  Разворачивает её контекст, а не панель: сколько столов у турнира и как
  они адресуются — знание ядра (§3 CLAUDE.md).

  Наружу контекст говорит только через `Phoenix.PubSub`.
  """

  import Ecto.Query

  alias BlockPoker.Admin.{Audit, Context}
  alias BlockPoker.Repo
  alias BlockPoker.Sounds.{Sound, Storage}
  alias BlockPoker.Tables
  alias BlockPoker.Tables.TableServer
  alias BlockPoker.Tournaments.TournamentServer
  alias Ecto.Multi

  @everyone_topic "announcements"

  @type target :: {:room, String.t()} | {:tournament, String.t()} | :everyone

  @type play :: %{
          id: String.t(),
          sound_id: Ecto.UUID.t(),
          title: String.t(),
          url: String.t(),
          at: DateTime.t()
        }

  @doc """
  Топик рассылки «всему залу».

  Тот же, на котором ходят объявления, и по той же причине, по какой он
  вообще существует: это единственный в системе топик, адресованный всем
  подключённым сразу. Заводить рядом второй такой же значило бы просить
  каждого клиента держать две подписки ради одного множества получателей.
  """
  @spec everyone_topic() :: String.t()
  def everyone_topic, do: @everyone_topic

  @doc """
  Адресат для строки игры из списка панели.

  Турнир — не стол: у `:mtt` свои столы, и звук в турнире это рассылка по
  всем ним. Соответствие живёт здесь, а не в контроллере, ровно потому,
  что это доменный факт о режимах (§3 CLAUDE.md).
  """
  @spec target(atom(), String.t()) :: target()
  def target(:mtt, id), do: {:tournament, id}
  def target(_kind, id), do: {:room, id}

  # --- библиотека -----------------------------------------------------------

  @doc "Вся библиотека, новые сверху."
  @spec list() :: [map()]
  def list do
    Sound
    |> order_by(desc: :inserted_at)
    |> preload(:uploaded_by)
    |> Repo.all()
    |> Enum.map(&card/1)
  end

  @doc """
  Кладёт новый звук в библиотеку.

  Файл ложится на диск **до** транзакции и убирается при её неудаче: в
  обратном порядке неудачная вставка оставила бы в базе строку, которой
  нечего играть.
  """
  @spec create(Context.t(), map()) :: {:ok, map()} | {:error, atom() | Ecto.Changeset.t()}
  def create(%Context{} = ctx, attrs) do
    title = trim(attrs[:title])

    with :ok <- ensure_title(title),
         :ok <- ensure_file(attrs[:path]),
         {:ok, stored} <- Storage.store(attrs[:path]) do
      changeset =
        Sound.changeset(%Sound{}, %{
          title: title,
          file: stored.file,
          bytes: stored.bytes,
          format: stored.format,
          uploaded_by_id: ctx.admin_id
        })

      Multi.new()
      |> Multi.insert(:sound, changeset)
      |> Audit.step(:audit, ctx, fn %{sound: sound} ->
        %{
          action: :sound_upload,
          subject_type: :sound,
          subject_id: sound.id,
          meta: %{title: sound.title, file: sound.file, bytes: sound.bytes}
        }
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{sound: sound}} ->
          {:ok, card(sound)}

        {:error, _step, reason, _changes} ->
          Storage.delete(stored.file)
          {:error, failure(reason)}
      end
    end
  end

  @doc "Убирает звук из библиотеки вместе с файлом."
  @spec delete(Context.t(), Ecto.UUID.t()) :: :ok | {:error, atom()}
  def delete(%Context{} = ctx, id) do
    with {:ok, sound} <- fetch(id) do
      Multi.new()
      |> Multi.delete(:sound, sound)
      |> Audit.step(:audit, ctx, %{
        action: :sound_delete,
        subject_type: :sound,
        subject_id: sound.id,
        meta: %{title: sound.title, file: sound.file}
      })
      |> Repo.transaction()
      |> case do
        {:ok, _changes} ->
          Storage.delete(sound.file)
          :ok

        {:error, _step, reason, _changes} ->
          {:error, failure(reason)}
      end
    end
  end

  # --- воспроизведение ------------------------------------------------------

  @doc """
  Проигрывает звук у всех, кто сейчас слышит указанного адресата.

  Журнал пишется **до** рассылки, как и у объявления: звук, которого нет
  в журнале, — это анонимный крик в зал. Отменить рассылку после
  неудачной записи всё равно нечем, и лучше не начинать.
  """
  @spec play(Context.t(), target(), Ecto.UUID.t()) :: {:ok, play()} | {:error, atom()}
  def play(%Context{} = ctx, target, sound_id) do
    with {:ok, sound} <- fetch(sound_id),
         {:ok, topics} <- topics(target) do
      play = %{
        id: Ecto.UUID.generate(),
        sound_id: sound.id,
        title: sound.title,
        url: Storage.url(sound.file),
        at: DateTime.utc_now()
      }

      case Audit.write(ctx, %{
             action: :sound_play,
             subject_type: :sound,
             subject_id: sound.id,
             meta: Map.merge(audit_target(target), %{title: sound.title, play_id: play.id})
           }) do
        {:ok, _entry} ->
          Enum.each(topics, &broadcast(&1, play))
          {:ok, play}

        {:error, _changeset} ->
          {:error, :internal_error}
      end
    end
  end

  # --- внутреннее -----------------------------------------------------------

  # Событие уходит тем же путём, что и остальные события стола: канал про
  # звук не знает и знать не должен.
  defp broadcast({:room, room_id}, play) do
    Phoenix.PubSub.broadcast(
      BlockPoker.PubSub,
      TableServer.topic(room_id),
      {:table_event, "sound", event(play)}
    )
  end

  defp broadcast({:everyone, topic}, play) do
    Phoenix.PubSub.broadcast(BlockPoker.PubSub, topic, {:sound, event(play)})
  end

  # То, что уходит в сокет. Время здесь уже строкой: событие идёт двумя
  # разными каналами, и приводить его в каждом по-своему — верный способ
  # получить два разных формата одного поля.
  defp event(play) do
    play
    |> Map.take([:id, :sound_id, :title, :url, :at])
    |> Map.update!(:at, &DateTime.to_iso8601/1)
  end

  # Куда именно уйдёт событие. Турнир разворачивается в свои столы: своего
  # топика, который слушали бы все его игроки сразу, у него нет — игрок
  # подписан на стол, за которым сидит.
  defp topics({:room, room_id}) do
    case Tables.room_state(room_id) do
      {:ok, _room} -> {:ok, [{:room, room_id}]}
      {:error, _reason} -> {:error, :admin_room_not_found}
    end
  end

  defp topics({:tournament, tournament_id}) do
    case TournamentServer.whereis(tournament_id) do
      nil -> {:error, :tournament_not_running}
      pid -> {:ok, Enum.map(TournamentServer.table_ids(pid), &{:room, &1})}
    end
  end

  defp topics(:everyone), do: {:ok, [{:everyone, @everyone_topic}]}

  defp topics(_other), do: {:error, :invalid_sound_target}

  defp audit_target({kind, id}), do: %{target: kind, target_id: id}
  defp audit_target(:everyone), do: %{target: :everyone, target_id: nil}

  defp card(%Sound{} = sound) do
    %{
      id: sound.id,
      title: sound.title,
      url: Storage.url(sound.file),
      bytes: sound.bytes,
      format: sound.format,
      inserted_at: sound.inserted_at,
      uploaded_by: uploaded_by(sound)
    }
  end

  defp uploaded_by(%Sound{uploaded_by: %{name: name}}), do: name
  defp uploaded_by(_sound), do: nil

  defp fetch(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> fetch_uuid(uuid)
      :error -> {:error, :not_found}
    end
  end

  defp fetch(_id), do: {:error, :not_found}

  defp fetch_uuid(uuid) do
    case Repo.get(Sound, uuid) do
      nil -> {:error, :not_found}
      sound -> {:ok, Repo.preload(sound, :uploaded_by)}
    end
  end

  defp trim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim(_value), do: nil

  defp ensure_title(nil), do: {:error, :sound_title_required}
  defp ensure_title(_title), do: :ok

  defp ensure_file(path) when is_binary(path), do: :ok
  defp ensure_file(_absent), do: {:error, :sound_file_required}

  defp failure(%Ecto.Changeset{} = changeset), do: changeset
  defp failure(reason) when is_atom(reason), do: reason
  defp failure(_reason), do: :internal_error
end
