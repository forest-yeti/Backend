defmodule BlockPoker.Chat do
  @moduledoc """
  Правила чата: что считается сообщением, как часто его можно слать и
  сколько строк помнит комната.

  Чат один и тот же везде — кэш, турнир, sit-n-go, — потому что он про
  людей за столом, а не про формат игры. Отличаться может только то, кому
  разрешено писать, и это решает стол, а не этот модуль.

  Контекст чистый и без БД: переписка за столом живёт в процессе комнаты и
  умирает вместе с ней. Хранить её в MySQL значило бы писать в БД по ходу
  раздачи — прямо против §1.4 CLAUDE.md; когда понадобится модерация,
  это будет отдельный поток в Oban, а не синхронная вставка.

  Ограничение частоты живёт здесь, а не в `Socket`, по той же причине, по
  какой там нет правил игры: «пять сообщений за десять секунд» — это норма
  рума, а не свойство транспорта.
  """

  @max_length 200
  @window_ms 10_000
  @max_in_window 5
  @history_limit 20

  @type message :: %{
          seat: pos_integer() | nil,
          user_id: Ecto.UUID.t(),
          name: String.t() | nil,
          text: String.t(),
          at: DateTime.t()
        }

  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @spec history_limit() :: pos_integer()
  def history_limit, do: @history_limit

  @doc """
  Приведение текста к отправляемому виду.

  Переводы строк схлопываются в пробел намеренно: сообщение в чате стола —
  одна строка, а «лесенка» из переводов строк выталкивает с экрана всё
  остальное. Это не косметика, а защита от самого дешёвого способа мешать
  соперникам.
  """
  @spec sanitize(term()) :: {:ok, String.t()} | {:error, :validation_failed | :chat_too_long}
  def sanitize(text) when is_binary(text) do
    cleaned =
      text
      |> String.replace(~r/[\p{C}\s]+/u, " ")
      |> String.trim()

    cond do
      cleaned == "" -> {:error, :validation_failed}
      String.length(cleaned) > @max_length -> {:error, :chat_too_long}
      true -> {:ok, cleaned}
    end
  end

  def sanitize(_text), do: {:error, :validation_failed}

  @doc """
  Проверка частоты по отметкам прошлых сообщений игрока.

  Возвращает обновлённый список отметок: старые за окном отбрасываются,
  поэтому он не растёт. Время передаётся аргументом — часы в ядре не
  берутся сами (§11 CLAUDE.md).
  """
  @spec throttle([integer()], integer()) :: {:ok, [integer()]} | {:error, :chat_rate_limited}
  def throttle(sent_at, now) do
    recent = Enum.filter(sent_at, &(now - &1 < @window_ms))

    if length(recent) >= @max_in_window do
      {:error, :chat_rate_limited}
    else
      {:ok, [now | recent]}
    end
  end

  @doc "Свежая история: последние сообщения, новое — в конце."
  @spec push([message()], message()) :: [message()]
  def push(history, message) do
    (history ++ [message]) |> Enum.take(-@history_limit)
  end
end
