defmodule BlockPoker.Engine.TimeBankTest do
  @moduledoc "Арифметика личного запаса времени."

  use ExUnit.Case, async: true

  alias BlockPoker.Engine.TimeBank

  test "стартовый запас равен потолку шаблона" do
    assert TimeBank.initial(30_000) == 30_000
  end

  test "списывается прошедшее время, но не больше остатка" do
    assert TimeBank.spend(30_000, 4_500) == 25_500
    assert TimeBank.spend(3_000, 10_000) == 0
    # Отрицательное прошедшее время банк не пополняет.
    assert TimeBank.spend(30_000, -5_000) == 30_000
  end

  test "пополнение упирается в потолок" do
    assert TimeBank.refill(5_000, 10_000, 30_000) == 15_000
    assert TimeBank.refill(28_000, 10_000, 30_000) == 30_000
  end

  test "пустой банк продлить размышление не может" do
    refute TimeBank.available?(0)
    assert TimeBank.available?(1)
  end
end
