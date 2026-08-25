defmodule BlockPoker.ClientReleaseTest do
  use ExUnit.Case, async: false

  alias BlockPoker.ClientRelease

  setup do
    previous = Application.get_env(:block_poker, :client_release, [])
    on_exit(fn -> Application.put_env(:block_poker, :client_release, previous) end)
    :ok
  end

  defp configure(opts), do: Application.put_env(:block_poker, :client_release, opts)

  test "сборка ниже минимума в игру не пускается" do
    configure(current: "1.4.2", minimum: "1.4.0")

    assert {:error, :client_too_old} = ClientRelease.check("1.3.9")
    assert {:error, :client_too_old} = ClientRelease.check("0.9.0")
  end

  test "сборка ровно на минимуме и выше пускается" do
    configure(current: "1.4.2", minimum: "1.4.0")

    assert :ok = ClientRelease.check("1.4.0")
    assert :ok = ClientRelease.check("1.4.2")
    assert :ok = ClientRelease.check("2.0.0")
  end

  test "версия сравнивается по semver, а не лексикографически" do
    configure(minimum: "1.9.0")

    assert :ok = ClientRelease.check("1.10.0")
    assert {:error, :client_too_old} = ClientRelease.check("1.8.0")
  end

  test "клиент новее минимума, но старее актуального — играет и знает про обновление" do
    configure(current: "1.4.2", minimum: "1.4.0")

    assert :ok = ClientRelease.check("1.4.1")
    assert ClientRelease.outdated?("1.4.1")
    refute ClientRelease.outdated?("1.4.2")
  end

  test "версия не передана — считается нулевой" do
    configure(minimum: "1.0.0")
    assert {:error, :client_too_old} = ClientRelease.check(nil)

    configure(minimum: "0.0.0")
    assert :ok = ClientRelease.check(nil)
  end

  test "мусор вместо версии гейт не обходит" do
    configure(minimum: "1.0.0")

    assert {:error, :client_too_old} = ClientRelease.check("не версия")
    assert {:error, :client_too_old} = ClientRelease.check("")
    assert {:error, :client_too_old} = ClientRelease.check(42)
  end

  test "ненастроенный минимум никого не отсекает" do
    configure([])

    assert :ok = ClientRelease.check("0.0.1")
    assert :ok = ClientRelease.check(nil)
  end

  test "битая граница в конфиге не превращается в массовый отказ" do
    configure(minimum: "мусор")

    assert :ok = ClientRelease.check("1.0.0")
  end

  test "info отдаёт обе границы и адрес фида" do
    configure(current: "1.4.2", minimum: "1.4.0", feed_url: "https://cdn/updates")

    assert ClientRelease.info() == %{
             current: "1.4.2",
             minimum: "1.4.0",
             feed_url: "https://cdn/updates"
           }
  end
end
