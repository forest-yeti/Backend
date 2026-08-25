defmodule Socket.Views.Admin.RoomView do
  @moduledoc """
  Сериализация god-mode.

  **Временный отладочный инструмент** — один из трёх файлов наблюдения
  (§13 задачи 8).

  От `TableView` отличается ровно тем, что ничего не прячет: снапшот
  приходит из `Admin.Observer` уже несфильтрованным, и здесь остаётся
  только развернуть карты в `%{rank, suit}`. Решения «что показать» тут
  нет — оно всё принято в ядре, и принято одинаково для всех мест.

  Карты в Logger не уходят: они едут в сокет и только туда (§8 задачи 8).
  """

  alias Socket.Views.TableView

  @doc "Полный снапшот стола: стеки, борд, все карманные карты, остаток колоды."
  @spec room(map()) :: map()
  def room(snapshot), do: TableView.cards(snapshot)

  @doc """
  Доменное событие ядра — тот же список событий, что уходит игрокам, но
  без фильтрации.
  """
  @spec delta(String.t(), term()) :: map()
  def delta(event, payload) do
    %{event: event, payload: TableView.event(event, payload)}
  end

  @doc """
  Приватное событие игрока: доезжает до наблюдателя как есть, вместе с
  адресатом — иначе непонятно, чьи это карты.
  """
  @spec private(Ecto.UUID.t(), String.t(), term()) :: map()
  def private(user_id, event, payload) do
    %{event: event, user_id: user_id, private: true, payload: TableView.cards(payload)}
  end

  @doc """
  Входящий запрос игрока: что прислали, кто и когда.

  Полезная нагрузка отдаётся как есть — это ровно то, что клиент положил
  в сообщение, и подчищать её значило бы прятать от отладки то, ради чего
  она открыта.
  """
  @spec intent(map()) :: map()
  def intent(event) do
    %{
      at: event.at,
      user_id: event.user_id,
      seat: event.seat,
      topic: event.topic,
      event: event.event,
      payload: event.payload,
      seq: event.seq
    }
  end

  @doc "Результат обработки: чем кончилось, с каким кодом и за сколько."
  @spec intent_result(map()) :: map()
  def intent_result(event) do
    %{
      at: event.at,
      user_id: event.user_id,
      event: event.event,
      outcome: outcome(event.outcome),
      code: event.code,
      latency_us: event.latency_us
    }
  end

  defp outcome(nil), do: "ok"
  defp outcome(outcome) when is_atom(outcome), do: Atom.to_string(outcome)
  defp outcome(outcome), do: outcome
end
