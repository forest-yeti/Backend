defmodule BlockPoker.Engine.Showdown do
  @moduledoc """
  Кто сильнее на вскрытии.

  Границы жёсткие: `Showdown` отвечает на вопрос «кто выиграл», а не «кому
  сколько». Сайд-поты и раздача фишек — дело `Engine.Pot`. Смешивать нельзя:
  правила сравнения зависят от варианта, правила деления банка — нет.

  Одинаковый `place` означает абсолютную ничью: банк делится.
  """

  alias BlockPoker.Engine.{Card, HandRank, Variant}

  @type player_id :: term()
  @type entry :: {player_id(), [Card.t()]}
  @type placement :: %{player_id: player_id(), rank: HandRank.t(), place: pos_integer()}

  @doc """
  Ранжировка игроков по силе руки.

  Для `pot_split() == :high` возвращает один список. Для `{:hi_lo, _}` —
  две независимые ранжировки: `%{high: [...], low: [...]}`, где `low` может
  быть пустым (никто не квалифицировался).
  """
  @spec showdown([entry()], [Card.t()], Variant.t() | HandRank.Context.t()) ::
          [placement()] | %{high: [placement()], low: [placement()]}
  def showdown(entries, board, variant_or_context) do
    context = context(variant_or_context)

    case context.variant.pot_split() do
      :high ->
        high(entries, board, context)

      {:hi_lo, low_evaluator} ->
        %{high: high(entries, board, context), low: low(entries, board, context, low_evaluator)}
    end
  end

  @doc "Идентификаторы игроков, делящих банк по high-шкале."
  @spec winners([entry()], [Card.t()], Variant.t() | HandRank.Context.t()) :: [player_id()]
  def winners(entries, board, variant_or_context) do
    entries
    |> high(board, context(variant_or_context))
    |> Enum.filter(&(&1.place == 1))
    |> Enum.map(& &1.player_id)
  end

  @doc "Лучшая рука одного игрока в терминах варианта."
  @spec evaluate([Card.t()], [Card.t()], Variant.t() | HandRank.Context.t()) :: HandRank.t() | nil
  def evaluate(hole, board, variant_or_context) do
    context = context(variant_or_context)

    hole
    |> context.variant.candidate_hands(board)
    |> HandRank.best_of(context)
  end

  defp high(entries, board, context) do
    entries
    |> Enum.map(fn {player_id, hole} -> {player_id, evaluate(hole, board, context)} end)
    |> Enum.reject(fn {_player_id, rank} -> is_nil(rank) end)
    |> place()
  end

  defp low(entries, board, context, low_evaluator) do
    entries
    |> Enum.map(fn {player_id, hole} ->
      candidates = context.variant.candidate_hands(hole, board)
      {player_id, low_evaluator.best_low(candidates, context)}
    end)
    |> Enum.flat_map(fn
      {player_id, {:ok, rank}} -> [{player_id, rank}]
      {_player_id, :not_qualified} -> []
    end)
    |> place()
  end

  # Место считается по числу *строго* более сильных рук: одинаковая сила даёт
  # одинаковое место, а следующее место сдвигается на размер группы.
  defp place(ranked) do
    ranked
    |> Enum.sort_by(fn {_player_id, rank} -> rank.score end, :desc)
    |> Enum.chunk_by(fn {_player_id, rank} -> rank.score end)
    |> Enum.flat_map_reduce(1, fn group, place ->
      placed =
        Enum.map(group, fn {player_id, rank} ->
          %{player_id: player_id, rank: rank, place: place}
        end)

      {placed, place + length(group)}
    end)
    |> elem(0)
  end

  defp context(%HandRank.Context{} = context), do: context
  defp context(variant), do: HandRank.context(variant)
end
