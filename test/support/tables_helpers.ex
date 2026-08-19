defmodule BlockPoker.TablesHelpers do
  @moduledoc """
  Помощники тестов процессов столов.

  Таймеры комнат в тестах **не отсчитываются реальным временем**: комната
  запускается в режиме `timers: :manual`, и срабатывание прогоняется вручную
  через `TableServer.fire_timer/2`. `Process.sleep` запрещён (§10 CLAUDE.md).
  """

  import BlockPoker.CashGamesFixtures
  import ExUnit.Callbacks, only: [start_supervised: 2]

  alias BlockPoker.Engine.Rng
  alias BlockPoker.Tables.{TableRegistry, TableServer, TableSupervisor}

  @doc """
  Реестр и супервизор комнат — из дерева приложения: они глобальные, а
  изоляцию тестов даёт уникальный `room_id` каждой комнаты, поэтому поднимать
  свои копии не нужно и `async: true` от этого не страдает.
  """
  def ensure_tables! do
    assert_started(TableRegistry)
    assert_started(TableSupervisor)
    :ok
  end

  defp assert_started(name) do
    case Process.whereis(name) do
      nil -> raise "#{inspect(name)} не запущен: проверьте дерево супервизоров"
      pid -> pid
    end
  end

  @doc """
  Управляемые часы: тайм-банк считает прошедшее время, и в тестах оно
  двигается вручную, а не ожиданием (§11 CLAUDE.md).

  Возвращает `{clock, advance}` — функцию часов для комнаты и функцию,
  сдвигающую их на нужное число миллисекунд.
  """
  def manual_clock(start \\ 0) do
    {:ok, agent} = Agent.start_link(fn -> start end)

    {fn -> Agent.get(agent, & &1) end, fn ms -> Agent.update(agent, &(&1 + ms)) end}
  end

  @doc "Комната с ручными таймерами и детерминированным RNG."
  def start_room!(overrides \\ %{}, opts \\ []) do
    setting = build_setting(overrides)
    room_id = Ecto.UUID.generate()

    {:ok, pid} =
      start_supervised(
        {TableServer,
         Keyword.merge(
           [
             room_id: room_id,
             setting: setting,
             timers: :manual,
             rng: Rng.seeded(Keyword.get(opts, :seed, "test"))
           ],
           Keyword.drop(opts, [:seed])
         )},
        id: room_id
      )

    %{pid: pid, room_id: room_id, setting: setting}
  end

  @doc """
  Посадка без похода в кошелёк: тесты уровня 2 проверяют комнату, а не
  деньги. Деньги проверяются на уровне 3, где есть настоящая БД.
  """
  def seat!(pid, user_id, seat, buy_in, entry \\ :wait_bb, profile \\ %{}) do
    {:ok, %{reservation_id: reservation_id}} =
      TableServer.reserve_seat(pid, user_id, seat, buy_in, profile)

    {:ok, seat} = TableServer.confirm_seat(pid, reservation_id, buy_in, entry)
    seat
  end

  @doc "Посадка администратора: роль снимается с профиля при посадке."
  def seat_admin!(pid, user_id, seat, buy_in, entry \\ :wait_bb) do
    seat!(pid, user_id, seat, buy_in, entry, %{role: :admin})
  end
end
