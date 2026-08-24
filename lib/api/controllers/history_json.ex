defmodule Api.HistoryJSON do
  @moduledoc """
  Рендер истории.

  Транспорт, а не логика: решает, какие поля показать, но не вычисляет
  новых доменных значений. Если здесь появилась арифметика над фишками —
  значение должно приходить из ядра уже посчитанным (§3 CLAUDE.md).

  Форма элемента списка зависит от дисциплины и объявляется полем `kind`,
  а не разными URL: для клиента это одна история с фильтром по режиму.
  """

  alias Api.HistoryParams

  def hands(%{page: page}) do
    # Элемент списка приходит из контекста уже в той форме, в какой его
    # видит этот игрок: чужих карт в нём нет, а `kind` объявляет
    # дисциплину. Перекладывать его по полю значило бы завести здесь
    # второе описание того, что показывает история.
    %{items: page.items, cursor: HistoryParams.encode_cursor(page.cursor)}
  end

  # Карты и сбросы уже отфильтрованы контекстом: скрытое приезжает сюда
  # пустым списком. Решать, показывать ли его, здесь нечем и незачем.
  def hand(%{replay: replay}), do: replay

  def stats(%{stats: stats, tournaments: tournaments}) do
    %{modes: stats, tournaments: tournaments}
  end

  def graph(%{points: points}), do: %{points: points}

  def tournaments(%{page: page}) do
    %{items: page.items, cursor: HistoryParams.encode_cursor(page.cursor)}
  end

  def tournament(%{result: result}), do: result
end
