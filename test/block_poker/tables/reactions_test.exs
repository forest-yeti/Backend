defmodule BlockPoker.Tables.ReactionsTest do
  @moduledoc """
  Реакции за столом как поведение комнаты: кто может слать, что уходит
  в топик и почему реакция не остаётся в состоянии.

  Часы инжектируются: кулдаун прогоняется вручную, а не ожиданием.
  """

  use ExUnit.Case, async: true

  import BlockPoker.TablesHelpers

  alias BlockPoker.Reactions
  alias BlockPoker.Tables.{RoomState, TableServer}
  alias Socket.Views.TableView

  setup do
    ensure_tables!()
    :ok
  end

  defp subscribe(room_id) do
    Phoenix.PubSub.subscribe(BlockPoker.PubSub, TableServer.topic(room_id))
  end

  describe "отправка" do
    test "реакция уходит в топик стола с местом и временем" do
      %{pid: pid, room_id: room_id} = start_room!()
      seat!(pid, "user-1", 3, 400)
      :ok = subscribe(room_id)

      assert :ok = TableServer.react(pid, "user-1", "fire")

      assert_receive {:table_event, "reaction", event}
      assert event.seat == 3
      assert event.user_id == "user-1"
      assert event.id == "fire"
      assert %DateTime{} = event.at
    end

    test "наблюдатель реакции не шлёт" do
      %{pid: pid} = start_room!()
      seat!(pid, "user-1", 1, 400)

      assert {:error, :not_seated} = TableServer.react(pid, "stranger", "fire")
    end

    test "вышедший в sit_out по-прежнему может" do
      %{pid: pid} = start_room!()
      seat!(pid, "user-1", 1, 400)
      seat!(pid, "user-2", 2, 400)
      {:ok, _} = TableServer.sit_out(pid, "user-1")

      assert :ok = TableServer.react(pid, "user-1", "salt")
    end

    test "id не из списка отвергается" do
      %{pid: pid} = start_room!()
      seat!(pid, "user-1", 1, 400)

      assert {:error, :validation_failed} = TableServer.react(pid, "user-1", "rocket")
      assert {:error, :validation_failed} = TableServer.react(pid, "user-1", "🔥")
      assert {:error, :validation_failed} = TableServer.react(pid, "user-1", nil)
    end
  end

  describe "кулдаун" do
    test "вторая реакция в ту же минуту отвергается с остатком" do
      {clock, advance} = manual_clock()
      %{pid: pid} = start_room!(%{}, clock: clock)
      seat!(pid, "user-1", 1, 400)

      assert :ok = TableServer.react(pid, "user-1", "fire")

      advance.(20_000)

      assert {:error, {:reaction_rate_limited, remaining}} =
               TableServer.react(pid, "user-1", "gg")

      assert remaining == Reactions.cooldown_ms() - 20_000

      # Кулдаун личный: сосед по столу молчать не обязан.
      seat!(pid, "user-2", 2, 400)
      assert :ok = TableServer.react(pid, "user-2", "gg")
    end

    test "через минуту снова можно" do
      {clock, advance} = manual_clock()
      %{pid: pid} = start_room!(%{}, clock: clock)
      seat!(pid, "user-1", 1, 400)

      assert :ok = TableServer.react(pid, "user-1", "fire")
      advance.(Reactions.cooldown_ms())
      assert :ok = TableServer.react(pid, "user-1", "clown")
    end

    test "отклонённая реакция кулдаун не продлевает" do
      {clock, advance} = manual_clock()
      %{pid: pid} = start_room!(%{}, clock: clock)
      seat!(pid, "user-1", 1, 400)

      assert :ok = TableServer.react(pid, "user-1", "fire")
      advance.(30_000)
      assert {:error, {:reaction_rate_limited, _ms}} = TableServer.react(pid, "user-1", "gg")

      # Отсчёт идёт от удавшейся реакции, а не от последней попытки.
      advance.(30_000)
      assert :ok = TableServer.react(pid, "user-1", "gg")
    end
  end

  describe "эфемерность" do
    test "реакция не остаётся ни в чате, ни в снапшоте" do
      %{pid: pid} = start_room!()
      seat!(pid, "user-1", 1, 400)

      :ok = TableServer.react(pid, "user-1", "fire")

      room = TableServer.state(pid)
      assert room.chat == []

      payload = room |> TableView.render("user-1") |> Jason.encode!()

      # В снапшоте есть только панель — сама реакция в него не попадает.
      assert payload =~ ~s("reactions")
      refute payload =~ ~s("id":"fire")
    end

    test "снапшот отдаёт набор в порядке отображения" do
      %{pid: pid} = start_room!()
      seat!(pid, "user-1", 1, 400)

      snapshot = pid |> TableServer.state() |> TableView.render("user-1")

      assert snapshot.reactions == Reactions.ids()
      assert snapshot.you.can_react
    end

    test "наблюдателю панель не показывается" do
      %{pid: pid} = start_room!()
      seat!(pid, "user-1", 1, 400)

      snapshot = pid |> TableServer.state() |> TableView.render("stranger")

      refute snapshot.you.can_react
      refute RoomState.can_react?(TableServer.state(pid), "stranger")
    end
  end
end
