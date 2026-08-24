defmodule Api.HistoryController do
  @moduledoc """
  История раздач и статистика игрока — единственное чтение проекта,
  вынесенное из сокета.

  Обоснование, которого §3 CLAUDE.md требует от каждого нового эндпоинта:
  история не real-time (сервер ничего не пушит, состояние не меняется под
  игроком), это чтение с пагинацией и фильтрами, ответ идемпотентен и
  кэшируется (`ETag`), а объём страницы не должен делить пропускную
  способность с игровым сокетом — тяжёлый ответ по каналу это лишние
  миллисекунды у чужого таймера хода за столом.

  Инвариант «в `api/*` нет бизнес-логики» при этом не ослабляется:
  контроллер достаёт `user_id` из `conn.assigns`, парсит параметры
  страницы, зовёт **одну** функцию контекста и рендерит. Ни фильтрации
  чужих карт, ни арифметики над фишками здесь нет — и то и другое живёт
  в `History`.
  """

  use Api, :controller

  alias Api.HistoryParams
  alias BlockPoker.History

  action_fallback Api.FallbackController

  def hands(conn, params) do
    with {:ok, opts} <- HistoryParams.list(params) do
      render(conn, :hands, page: History.list_hands(conn.assigns.user_id, opts))
    end
  end

  def hand(conn, %{"id" => id}) do
    with {:ok, replay} <- History.get_hand(conn.assigns.user_id, id) do
      conn
      |> cache_immutable(replay)
      |> render(:hand, replay: replay)
    end
  end

  def stats(conn, params) do
    with {:ok, opts} <- HistoryParams.period(params) do
      stats = History.stats(conn.assigns.user_id, opts)

      # Турнирная сводка считается в той же валюте, что и режимы: иначе
      # ROI сложил бы центы с игровыми фишками.
      tournaments =
        History.tournament_summary(
          conn.assigns.user_id,
          Map.put(opts, :currency, stats.currency)
        )

      render(conn, :stats, stats: stats, tournaments: tournaments)
    end
  end

  def graph(conn, params) do
    with {:ok, opts} <- HistoryParams.period(params) do
      render(conn, :graph, points: History.graph(conn.assigns.user_id, opts))
    end
  end

  def tournaments(conn, params) do
    with {:ok, opts} <- HistoryParams.tournaments(params) do
      render(conn, :tournaments, page: History.list_tournaments(conn.assigns.user_id, opts))
    end
  end

  def tournament(conn, %{"id" => id}) do
    with {:ok, result} <- History.get_tournament(conn.assigns.user_id, id) do
      render(conn, :tournament, result: result)
    end
  end

  # Раздача неизменна с момента записи, поэтому ответ кэшируется целиком.
  # Кроме одного случая: пока окно показа не закрылось, видимость карт ещё
  # может измениться вторым апдейтом, и `immutable` тогда соврал бы.
  defp cache_immutable(conn, replay) do
    conn
    |> put_resp_header("etag", etag(replay))
    |> put_resp_header("cache-control", "private, max-age=86400, immutable")
  end

  defp etag(replay) do
    replay |> :erlang.phash2() |> Integer.to_string(16) |> then(&~s("#{&1}"))
  end
end
