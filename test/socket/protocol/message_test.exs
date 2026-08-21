defmodule Socket.Protocol.MessageTest do
  @moduledoc """
  Разбор входящих payload. Транспорт проверяет только форму: что за карты
  игрок вправе открыть, решает контекст, а не этот модуль.
  """

  use ExUnit.Case, async: true

  alias Socket.Protocol.Message

  describe "card_indexes/1" do
    test "без поля открываются все карты" do
      assert Message.card_indexes(%{}) == :all
    end

    test "список индексов проходит как есть" do
      assert Message.card_indexes(%{"cards" => [0, 1]}) == [0, 1]
      assert Message.card_indexes(%{"cards" => [1]}) == [1]
    end

    test "мусор в списке отсеивается по форме" do
      assert Message.card_indexes(%{"cards" => [0, "1", -3, nil, 2.5]}) == [0]
    end

    test "не список — значит, поля нет" do
      assert Message.card_indexes(%{"cards" => "all"}) == :all
    end
  end
end
