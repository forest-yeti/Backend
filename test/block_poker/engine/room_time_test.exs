defmodule BlockPoker.Engine.RoomTimeTest do
  @moduledoc """
  Перевод расписания рума в UTC, включая оба разрыва перехода на летнее
  время.

  Разрывы проверяются на `Europe/Berlin`, а не на поясе рума: в Москве
  с 2014 года перехода нет вовсе, и тест на ней проверял бы не то, что
  написано в коде. Пояс подставляется аргументом ровно ради этого.
  """

  use ExUnit.Case, async: true

  alias BlockPoker.Engine.RoomTime

  @berlin "Europe/Berlin"
  @moscow "Europe/Moscow"

  describe "обычный перевод" do
    test "московские 21:30 — это 18:30 UTC" do
      assert {:ok, ~U[2026-09-01 18:30:00Z]} =
               RoomTime.to_utc(~D[2026-09-01], ~T[21:30:00], @moscow)
    end

    test "летнее время Берлина даёт сдвиг в два часа" do
      assert {:ok, ~U[2026-07-01 19:30:00Z]} =
               RoomTime.to_utc(~D[2026-07-01], ~T[21:30:00], @berlin)
    end

    test "зимнее время того же пояса — сдвиг в час" do
      assert {:ok, ~U[2026-01-15 20:30:00Z]} =
               RoomTime.to_utc(~D[2026-01-15], ~T[21:30:00], @berlin)
    end
  end

  describe "часы перевели вперёд: локального времени не было" do
    test "запуск сдвигается на длину разрыва, а не пропадает" do
      # 29 марта 2026 в Берлине 02:00 сразу становится 03:00 — 02:30
      # не существует. Турнир обязан состояться: расписание обещало вечер.
      assert {:ok, moment} = RoomTime.to_utc(~D[2026-03-29], ~T[02:30:00], @berlin)

      assert moment == ~U[2026-03-29 01:30:00Z]
    end

    test "после сдвига локальное время попадает уже в летний сдвиг" do
      {:ok, moment} = RoomTime.to_utc(~D[2026-03-29], ~T[02:30:00], @berlin)
      local = DateTime.shift_zone!(moment, @berlin)

      assert local.hour == 3
      assert local.minute == 30
    end
  end

  describe "часы перевели назад: локальное время существует дважды" do
    test "берётся первое вхождение" do
      # 25 октября 2026 в Берлине 02:30 случается дважды: сперва по
      # летнему сдвигу (00:30 UTC), потом по зимнему (01:30 UTC).
      assert {:ok, ~U[2026-10-25 00:30:00Z]} =
               RoomTime.to_utc(~D[2026-10-25], ~T[02:30:00], @berlin)
    end

    test "второе вхождение не порождает второго запуска" do
      # Иначе в одну ночь прошли бы два одинаковых турнира — то есть
      # дубль призового фонда и дубль оверлея.
      occurrences =
        RoomTime.occurrences(
          %{start_time: ~T[02:30:00], weekday: nil, repeat: true, run_on: nil},
          ~U[2026-10-25 00:00:00Z],
          ~U[2026-10-25 05:00:00Z],
          @berlin
        )

      assert length(occurrences) == 1
    end
  end

  describe "перечисление запусков" do
    test "ежедневное расписание даёт по запуску в сутки" do
      occurrences =
        RoomTime.occurrences(
          %{start_time: ~T[21:30:00], weekday: nil, repeat: true, run_on: nil},
          ~U[2026-09-01 00:00:00Z],
          ~U[2026-09-03 23:59:00Z],
          @moscow
        )

      assert length(occurrences) == 3
    end

    test "недельное расписание отбирает только свой день" do
      # 5 сентября 2026 — суббота.
      occurrences =
        RoomTime.occurrences(
          %{start_time: ~T[21:30:00], weekday: 6, repeat: true, run_on: nil},
          ~U[2026-09-01 00:00:00Z],
          ~U[2026-09-08 23:59:00Z],
          @moscow
        )

      assert [moment] = occurrences
      assert moment |> DateTime.shift_zone!(@moscow) |> DateTime.to_date() == ~D[2026-09-05]
    end

    test "разовый запуск срабатывает один раз и только в свою дату" do
      occurrences =
        RoomTime.occurrences(
          %{start_time: ~T[21:30:00], weekday: nil, repeat: false, run_on: ~D[2026-09-02]},
          ~U[2026-09-01 00:00:00Z],
          ~U[2026-09-05 23:59:00Z],
          @moscow
        )

      assert [~U[2026-09-02 18:30:00Z]] = occurrences
    end

    test "разовый запуск вне окна не возвращается" do
      occurrences =
        RoomTime.occurrences(
          %{start_time: ~T[21:30:00], weekday: nil, repeat: false, run_on: ~D[2026-12-31]},
          ~U[2026-09-01 00:00:00Z],
          ~U[2026-09-05 23:59:00Z],
          @moscow
        )

      assert occurrences == []
    end

    test "запуски идут по возрастанию" do
      occurrences =
        RoomTime.occurrences(
          %{start_time: ~T[21:30:00], weekday: nil, repeat: true, run_on: nil},
          ~U[2026-09-01 00:00:00Z],
          ~U[2026-09-05 23:59:00Z],
          @moscow
        )

      assert occurrences == Enum.sort(occurrences, DateTime)
    end

    test "границы окна включаются" do
      occurrences =
        RoomTime.occurrences(
          %{start_time: ~T[21:30:00], weekday: nil, repeat: true, run_on: nil},
          ~U[2026-09-01 18:30:00Z],
          ~U[2026-09-01 18:30:00Z],
          @moscow
        )

      assert [~U[2026-09-01 18:30:00Z]] = occurrences
    end
  end

  describe "пояс рума" do
    test "берётся из конфига" do
      assert RoomTime.timezone() == @moscow
    end
  end
end
