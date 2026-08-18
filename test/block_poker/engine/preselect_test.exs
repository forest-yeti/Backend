defmodule BlockPoker.Engine.PreselectTest do
  @moduledoc """
  Заранее выбранное действие: разбор выбора и его столкновение с реальной
  обстановкой на момент хода.
  """

  use ExUnit.Case, async: true

  alias BlockPoker.Engine.Preselect

  defp free, do: %{fold: true, check: true, call: nil, raise: nil, all_in: 100}
  defp facing_bet, do: %{fold: true, check: false, call: 40, raise: nil, all_in: 100}

  describe "parse/1" do
    test "принимает свои варианты строкой и атомом" do
      assert Preselect.parse("check_fold") == {:ok, :check_fold}
      assert Preselect.parse(:call_any) == {:ok, :call_any}
    end

    test "пустой выбор — это снятие выбора, а не ошибка" do
      assert Preselect.parse(nil) == {:ok, nil}
      assert Preselect.parse("none") == {:ok, nil}
      assert Preselect.parse("clear") == {:ok, nil}
    end

    test "неизвестный вариант отвергается" do
      assert Preselect.parse("raise_pot") == {:error, :validation_failed}
      assert Preselect.parse(42) == {:error, :validation_failed}
    end
  end

  describe "resolve/2" do
    test "фолд сбрасывает при любой обстановке" do
      assert Preselect.resolve(:fold, free()) == {:act, :fold}
      assert Preselect.resolve(:fold, facing_bet()) == {:act, :fold}
    end

    test "check-fold: бесплатно — чек, платно — сброс" do
      assert Preselect.resolve(:check_fold, free()) == {:act, :check}
      assert Preselect.resolve(:check_fold, facing_bet()) == {:act, :fold}
    end

    test "чек против ставки не сбрасывает руку, а снимает выбор" do
      # Главное отличие от check-fold: игрок просил чек, а не пас.
      assert Preselect.resolve(:check, free()) == {:act, :check}
      assert Preselect.resolve(:check, facing_bet()) == :cancel
    end

    test "call-any платит сколько попросят, а бесплатно просто чекает" do
      assert Preselect.resolve(:call_any, facing_bet()) == {:act, :call}
      assert Preselect.resolve(:call_any, free()) == {:act, :check}
    end

    test "без выбора стол ждёт игрока" do
      assert Preselect.resolve(nil, free()) == :none
    end
  end
end
