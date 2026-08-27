defmodule BlockPoker.Announcements do
  @moduledoc """
  Объявление всем игрокам: текст, который администратор отправляет в зал,
  и клиент показывает модальным окном.

  **Сущности нет намеренно.** Объявление — это не запись, а событие:
  «через 15 минут технические работы» имеет смысл ровно в тот момент,
  когда его отправили. Хранить его значило бы завести срок актуальности,
  чистку протухших и вопрос «показывать ли зашедшему через час» — весь
  этот механизм нужен только затем, чтобы обслуживать данные, которые
  через десять минут никому не нужны.

  Поэтому здесь нет ни таблицы, ни процесса с состоянием: контекст
  проверяет текст, пишет факт отправки в журнал и рассылает событие.
  Кто в этот момент онлайн — тот и увидел. Повторить объявление стоит
  одного нажатия, а вот объяснить игроку, почему ему показали вчерашние
  техработы, — не стоит ничего, кроме доверия.

  Следствие, которое важно для панели: **отозвать объявление нельзя.**
  Оно уже ушло. Кнопки «снять» нет, и это не упущение.

  Наружу контекст говорит через `Phoenix.PubSub`, как и все остальные
  (§3 CLAUDE.md): кто подписан на топик — его не касается.
  """

  alias BlockPoker.Admin.{Audit, Context}

  @topic "announcements"

  @max_title 200
  @max_text 1000

  @type announcement :: %{
          id: String.t(),
          title: String.t() | nil,
          text: String.t(),
          at: DateTime.t()
        }

  @doc "Топик рассылки. Канал подписывается на него, контекст — публикует."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Отправляет объявление всем подключённым игрокам.

  `id` генерируется здесь и уходит клиенту: одно и то же объявление может
  прийти дважды (реконнект в момент отправки), и клиенту нужен признак,
  по которому он поймёт, что модалку он уже показывал. Сервер про
  показанное не помнит ничего — помнить это дешевле на клиенте.
  """
  @spec announce(Context.t(), map()) :: {:ok, announcement()} | {:error, atom()}
  def announce(%Context{} = ctx, attrs) do
    title = trim(attrs[:title])
    text = trim(attrs[:text])

    with :ok <- ensure_text(text),
         :ok <- ensure_length(title, @max_title),
         :ok <- ensure_length(text, @max_text) do
      announcement = %{
        id: Ecto.UUID.generate(),
        title: title,
        text: text,
        at: DateTime.utc_now()
      }

      # Журнал пишется **до** рассылки: объявление, которого нет в
      # журнале, — это анонимное сообщение всему руму. Рассылка после
      # неудачной записи не отменяется никак, и лучше не начинать.
      case Audit.write(ctx, %{
             action: :announcement,
             subject_type: :announcement,
             subject_id: announcement.id,
             meta: %{title: title, text: text}
           }) do
        {:ok, _entry} ->
          Phoenix.PubSub.broadcast(BlockPoker.PubSub, @topic, {:announcement, announcement})
          {:ok, announcement}

        {:error, _changeset} ->
          {:error, :internal_error}
      end
    end
  end

  defp trim(nil), do: nil

  defp trim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim(_value), do: nil

  defp ensure_text(nil), do: {:error, :announcement_text_required}
  defp ensure_text(_text), do: :ok

  defp ensure_length(nil, _max), do: :ok

  defp ensure_length(value, max) do
    if String.length(value) > max, do: {:error, :announcement_too_long}, else: :ok
  end
end
