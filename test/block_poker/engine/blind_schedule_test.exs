defmodule BlockPoker.Engine.BlindScheduleTest do
  @moduledoc """
  Структура уровней: какие номиналы действуют и что происходит на краях.
  """

  use ExUnit.Case, async: true

  alias BlockPoker.Engine.BlindSchedule

  defp blinds do
    [
      %{level: 1, small_blind: 10, big_blind: 20, ante: 0, duration_seconds: 180},
      %{level: 2, small_blind: 15, big_blind: 30, ante: 0, duration_seconds: 180},
      %{level: 3, small_blind: 20, big_blind: 40, ante: 0, duration_seconds: 120}
    ]
  end

  defp antes do
    [
      %{level: 1, small_blind: 0, big_blind: 0, ante: 10, duration_seconds: 180},
      %{level: 2, small_blind: 0, big_blind: 0, ante: 15, duration_seconds: 180}
    ]
  end

  describe "at/2" do
    test "отдаёт уровень с запрошенным номером" do
      assert BlindSchedule.at(blinds(), 2).big_blind == 30
    end

    test "за краем таблицы действует последний уровень" do
      assert BlindSchedule.at(blinds(), 4) == BlindSchedule.last(blinds())
      assert BlindSchedule.at(blinds(), 99).big_blind == 40
    end

    test "пустая структура — ошибка конфигурации, а не молчаливый ноль" do
      assert_raise ArgumentError, fn -> BlindSchedule.at([], 1) end
    end
  end

  describe "next?/2" do
    test "на последнем уровне расти больше некуда" do
      refute BlindSchedule.next?(blinds(), 3)
      refute BlindSchedule.next?(blinds(), 10)
    end

    test "до последнего уровня — есть" do
      assert BlindSchedule.next?(blinds(), 1)
      assert BlindSchedule.next?(blinds(), 2)
    end
  end

  describe "duration_ms/2" do
    test "секунды расписания переводятся в миллисекунды таймера" do
      assert BlindSchedule.duration_ms(blinds(), 1) == 180_000
      assert BlindSchedule.duration_ms(blinds(), 3) == 120_000
    end
  end

  describe "limits/1" do
    test "отдаёт то, что читает bet_unit структуры ставок" do
      assert BlindSchedule.limits(BlindSchedule.first(blinds())) == %{big_blind: 20, ante: 0}
      assert BlindSchedule.limits(BlindSchedule.first(antes())) == %{big_blind: 0, ante: 10}
    end
  end

  describe "label/1" do
    test "блайндовый уровень подписывается парой номиналов" do
      assert BlindSchedule.label(BlindSchedule.first(blinds())) == "10/20"
    end

    test "уровень без блайндов подписывается анте — это Short Deck" do
      assert BlindSchedule.label(BlindSchedule.first(antes())) == "анте 10"
    end

    test "блайнды с анте показывают анте в скобках" do
      level = %{level: 5, small_blind: 40, big_blind: 80, ante: 10, duration_seconds: 180}

      assert BlindSchedule.label(level) == "40/80 (10)"
    end
  end
end
