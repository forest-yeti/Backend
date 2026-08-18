defmodule BlockPoker.Engine.Card do
  @moduledoc """
  Карта — целое число 0..51 (`rank * 4 + suit`).

  Внутреннее представление выбрано ради калькулятора эквити: он прогоняет
  миллионы раскладов, и структура на каждую карту означала бы миллионы
  аллокаций вместо арифметики. Структуры и карты остаются на границе —
  здесь это `from_map/1` и `to_map/1`.

  Ранги внутри нумеруются от младшего к старшему (0 = двойка, 12 = туз),
  чтобы сравнение было обычным `>` без таблиц перевода. Наружу ранг уходит
  в привычной игроку шкале 2..14.
  """

  @type t :: 0..51
  @type rank :: 0..12
  @type suit :: 0..3
  @type external_rank :: 2..14

  @suits {"S", "H", "D", "C"}
  @suit_index %{"S" => 0, "H" => 1, "D" => 2, "C" => 3}

  @doc "Внутренний ранг карты: 0 = двойка, 12 = туз."
  @spec rank(t()) :: rank()
  def rank(card), do: div(card, 4)

  @doc "Масть карты: 0 = пики, 1 = черви, 2 = бубны, 3 = трефы."
  @spec suit(t()) :: suit()
  def suit(card), do: rem(card, 4)

  @doc "Карта из внутреннего ранга и масти."
  @spec new(rank(), suit()) :: t()
  def new(rank, suit) when rank in 0..12 and suit in 0..3, do: rank * 4 + suit

  @spec valid?(term()) :: boolean()
  def valid?(card), do: is_integer(card) and card >= 0 and card <= 51

  @doc """
  Разбор внешнего представления `%{"rank" => 14, "suit" => "S"}`.

  Принимает и атомные ключи — тесты и внутренние вызовы пишут их короче.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, :invalid_card}
  def from_map(%{} = map) do
    with {:ok, rank} <- fetch(map, :rank, "rank"),
         {:ok, suit} <- fetch(map, :suit, "suit"),
         {:ok, rank} <- internal_rank(rank),
         {:ok, suit} <- internal_suit(suit) do
      {:ok, new(rank, suit)}
    end
  end

  def from_map(_), do: {:error, :invalid_card}

  @doc "Внешнее представление карты."
  @spec to_map(t()) :: %{rank: external_rank(), suit: String.t()}
  def to_map(card) when is_integer(card) do
    %{rank: rank(card) + 2, suit: elem(@suits, suit(card))}
  end

  @doc "Разбор списка карт: любая некорректная карта роняет весь список."
  @spec from_list([map()]) :: {:ok, [t()]} | {:error, :invalid_card}
  def from_list(maps) when is_list(maps) do
    Enum.reduce_while(maps, {:ok, []}, fn map, {:ok, acc} ->
      case from_map(map) do
        {:ok, card} -> {:cont, {:ok, [card | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, cards} -> {:ok, Enum.reverse(cards)}
      error -> error
    end
  end

  def from_list(_), do: {:error, :invalid_card}

  @spec to_list([t()]) :: [%{rank: external_rank(), suit: String.t()}]
  def to_list(cards), do: Enum.map(cards, &to_map/1)

  @doc """
  Короткая запись карты (`"AS"`, `"TH"`) — только для тестов, логов и разбора.
  В протокол уходит `to_map/1`.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, :invalid_card}
  def parse(<<rank::binary-1, suit::binary-1>>) do
    with {:ok, rank} <- short_rank(rank),
         {:ok, suit} <- internal_suit(suit) do
      {:ok, new(rank, suit)}
    end
  end

  def parse(_), do: {:error, :invalid_card}

  @spec parse!(String.t()) :: t()
  def parse!(string) do
    case parse(string) do
      {:ok, card} -> card
      {:error, _} -> raise ArgumentError, "некорректная карта: #{inspect(string)}"
    end
  end

  @doc "Разбор строки вида `\"AS KH\"` — список карт."
  @spec parse_many!(String.t()) :: [t()]
  def parse_many!(string) do
    string
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.map(&parse!/1)
  end

  @spec to_string(t()) :: String.t()
  def to_string(card) do
    ranks = {"2", "3", "4", "5", "6", "7", "8", "9", "T", "J", "Q", "K", "A"}
    elem(ranks, rank(card)) <> elem(@suits, suit(card))
  end

  defp fetch(map, atom_key, string_key) do
    case map do
      %{^atom_key => value} -> {:ok, value}
      %{^string_key => value} -> {:ok, value}
      _ -> {:error, :invalid_card}
    end
  end

  defp internal_rank(rank) when is_integer(rank) and rank in 2..14, do: {:ok, rank - 2}
  defp internal_rank(_), do: {:error, :invalid_card}

  defp internal_suit(suit) when is_binary(suit) do
    case Map.fetch(@suit_index, String.upcase(suit)) do
      {:ok, index} -> {:ok, index}
      :error -> {:error, :invalid_card}
    end
  end

  defp internal_suit(_), do: {:error, :invalid_card}

  defp short_rank(rank) do
    index =
      case String.upcase(rank) do
        "T" -> 8
        "J" -> 9
        "Q" -> 10
        "K" -> 11
        "A" -> 12
        digit -> digit_rank(digit)
      end

    if index, do: {:ok, index}, else: {:error, :invalid_card}
  end

  defp digit_rank(digit) do
    case Integer.parse(digit) do
      {value, ""} when value in 2..9 -> value - 2
      _ -> nil
    end
  end
end
