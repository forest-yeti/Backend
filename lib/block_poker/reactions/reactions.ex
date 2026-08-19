defmodule BlockPoker.Reactions do
  @moduledoc """
  Правила реакций за столом: какие бывают, как часто их можно слать.

  Реакция — короткий жест «в стол»: всплыла над аватаром отправителя и
  погасла. Её видят все, кто сейчас смотрит на стол, и никто — потом:
  в историю она не попадает и при реконнекте не переигрывается.

  **Наружу уходит id, а не символ.** Юникода нет ни в протоколе, ни в БД:
  версии эмодзи, ZWJ-последовательности и вариационные селекторы ломаются
  при нормализации, а произвольный символ в обход фильтра чата — готовый
  способ написать за столом что угодно. Картинку за id рисует клиент, и
  сменить её он может без участия сервера. Обратное правило — на клиенте:
  неизвестный id не рисуется вовсе, иначе старая сборка покажет пустой
  квадрат вместо смайлика.

  Порядок списка — порядок панели на экране. Он часть протокола: клиент
  рисует панель ровно этим списком, а не своим представлением о нём.

  Модуль чистый, как и `BlockPoker.Chat`: ни процессов, ни БД, ни часов —
  время приходит аргументом (§11 CLAUDE.md).
  """

  @ids ~w(fire laugh cry gg clown think salt)

  # Раз в минуту. Реакция дешевле сообщения в чате и заметнее его: она
  # всплывает поверх стола у всех сразу, поэтому окно здесь не «пять за
  # десять секунд», как в чате, а одно нажатие на игрока.
  @cooldown_ms 60_000

  @type id :: String.t()

  @type event :: %{
          seat: pos_integer(),
          user_id: Ecto.UUID.t(),
          id: id(),
          at: DateTime.t()
        }

  @doc "Доступный набор в порядке отображения — им же клиент рисует панель."
  @spec ids() :: [id()]
  def ids, do: @ids

  @spec cooldown_ms() :: pos_integer()
  def cooldown_ms, do: @cooldown_ms

  @doc "Известен ли id. Всё остальное — `validation_failed`, а не «пустой смайлик»."
  @spec valid?(term()) :: boolean()
  def valid?(id) when is_binary(id), do: id in @ids
  def valid?(_id), do: false

  @spec fetch(term()) :: {:ok, id()} | {:error, :validation_failed}
  def fetch(id) do
    if valid?(id), do: {:ok, id}, else: {:error, :validation_failed}
  end

  @doc """
  Проверка кулдауна по отметке прошлой реакции игрока.

  При отказе возвращается остаток в миллисекундах: клиенту он нужен, чтобы
  показать таймер, а не ошибку — нажатие на кнопку, которая «не работает
  без объяснений», игрок повторяет, и отказов становится больше.
  """
  @spec throttle(integer() | nil, integer()) ::
          {:ok, integer()} | {:error, {:reaction_rate_limited, pos_integer()}}
  def throttle(nil, now), do: {:ok, now}

  def throttle(last_at, now) do
    elapsed = now - last_at

    if elapsed >= @cooldown_ms do
      {:ok, now}
    else
      {:error, {:reaction_rate_limited, @cooldown_ms - elapsed}}
    end
  end
end
