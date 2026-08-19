defmodule BlockPoker.ReactionsTest do
  @moduledoc """
  Правила реакций: закрытый список id и кулдаун. Без БД и без процессов.
  """

  use ExUnit.Case, async: true

  alias BlockPoker.Reactions

  describe "набор" do
    test "стартовый список и его порядок — часть протокола" do
      assert Reactions.ids() == ~w(fire laugh cry gg clown think salt)
    end

    test "известен только id из списка" do
      assert Reactions.valid?("fire")
      refute Reactions.valid?("FIRE")
      refute Reactions.valid?("rocket")
      refute Reactions.valid?("")
      refute Reactions.valid?(nil)
      refute Reactions.valid?(:fire)
    end

    test "юникод в протокол не пролезает" do
      refute Reactions.valid?("🔥")
      refute Reactions.valid?("👨‍👩‍👧")
      refute Reactions.valid?("❤️")
    end

    test "fetch отвечает кодом ошибки, а не падением" do
      assert {:ok, "gg"} = Reactions.fetch("gg")
      assert {:error, :validation_failed} = Reactions.fetch("🤡")
    end
  end

  describe "кулдаун" do
    test "первая реакция проходит" do
      assert {:ok, 1_000} = Reactions.throttle(nil, 1_000)
    end

    test "вторая в ту же минуту отвергается с остатком времени" do
      cooldown = Reactions.cooldown_ms()

      assert {:error, {:reaction_rate_limited, remaining}} =
               Reactions.throttle(1_000, 1_000 + 20_000)

      assert remaining == cooldown - 20_000
    end

    test "по истечении кулдауна снова можно" do
      cooldown = Reactions.cooldown_ms()

      assert {:ok, _now} = Reactions.throttle(1_000, 1_000 + cooldown)
      assert {:ok, _now} = Reactions.throttle(1_000, 1_000 + cooldown + 1)
    end

    test "остаток всегда положителен и не больше кулдауна" do
      cooldown = Reactions.cooldown_ms()

      for elapsed <- [0, 1, 100, cooldown - 1] do
        assert {:error, {:reaction_rate_limited, remaining}} =
                 Reactions.throttle(0, elapsed)

        assert remaining > 0
        assert remaining <= cooldown
      end
    end
  end
end
