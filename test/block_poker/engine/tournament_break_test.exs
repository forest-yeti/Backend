defmodule BlockPoker.Engine.TournamentBreakTest do
  @moduledoc """
  Перерывы турнира: `XX:55`, пять минут, отсчёт от последней доигранной
  раздачи.

  Ключевое здесь — что перерыв **не сокращается**, когда раздача
  затянулась: игрок за медленным столом иначе получил бы перерыв короче
  остальных, а перерыв нужен ему физически, а не номинально.
  """

  use ExUnit.Case, async: true

  alias BlockPoker.Engine.TournamentBreak

  describe "константы рума" do
    test "останавливаемся в 55 минут" do
      assert TournamentBreak.minute_of_hour() == 55
    end

    test "перерыв длится пять минут" do
      assert TournamentBreak.duration_seconds() == 300
      assert TournamentBreak.duration_ms() == 300_000
    end
  end

  describe "ближайшая остановка" do
    test "до 55 минут — в этом же часу" do
      assert TournamentBreak.next_stop(~U[2026-09-01 21:30:00Z]) == ~U[2026-09-01 21:55:00Z]
    end

    test "после 55 минут — в следующем" do
      assert TournamentBreak.next_stop(~U[2026-09-01 21:57:00Z]) == ~U[2026-09-01 22:55:00Z]
    end

    test "ровно в 55 — следующая остановка через час" do
      # Иначе перерыв, только что закончившийся, начался бы снова
      # той же секундой.
      assert TournamentBreak.next_stop(~U[2026-09-01 21:55:00Z]) == ~U[2026-09-01 22:55:00Z]
    end

    test "переход через полночь" do
      assert TournamentBreak.next_stop(~U[2026-09-01 23:56:00Z]) == ~U[2026-09-02 00:55:00Z]
    end
  end

  describe "пора ли останавливаться" do
    test "до срока — нет" do
      refute TournamentBreak.stop?(~U[2026-09-01 21:54:59Z], ~U[2026-09-01 21:55:00Z])
    end

    test "ровно в срок — да" do
      assert TournamentBreak.stop?(~U[2026-09-01 21:55:00Z], ~U[2026-09-01 21:55:00Z])
    end

    test "просроченный момент — да" do
      assert TournamentBreak.stop?(~U[2026-09-01 22:10:00Z], ~U[2026-09-01 21:55:00Z])
    end
  end

  describe "ожидание до остановки" do
    test "считается в миллисекундах" do
      assert TournamentBreak.until_stop_ms(~U[2026-09-01 21:54:00Z]) == 60_000
    end

    test "отрицательного ожидания не бывает" do
      # Просроченный таймер обязан сработать немедленно, а не уехать
      # в прошлое.
      assert TournamentBreak.until_stop_ms(~U[2026-09-01 21:55:00Z]) >= 0
    end
  end

  describe "конец перерыва" do
    test "пять минут от момента, когда доиграла последняя раздача" do
      assert TournamentBreak.ends_at(~U[2026-09-01 21:56:30Z]) == ~U[2026-09-01 22:01:30Z]
    end

    test "затянувшаяся раздача сдвигает перерыв, но не укорачивает его" do
      # Остановка объявлена в 21:55, а последний стол доиграл в 22:03.
      # Перерыв всё равно длится полные пять минут.
      finished = ~U[2026-09-01 22:03:00Z]
      ends = TournamentBreak.ends_at(finished)

      assert DateTime.diff(ends, finished, :second) == TournamentBreak.duration_seconds()
    end
  end
end
