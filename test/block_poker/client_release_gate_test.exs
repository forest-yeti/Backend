defmodule BlockPoker.ClientReleaseGateTest do
  @moduledoc """
  Границы версий на значениях из конфигурации: нода, на которую через
  панель ещё ничего не заливали, обязана работать ровно так же.
  """

  use ExUnit.Case, async: false

  alias BlockPoker.ClientReleases
  alias BlockPoker.ClientReleases.Feed

  setup do
    previous = Application.get_env(:block_poker, :client_release, [])
    Feed.reset()

    on_exit(fn ->
      Application.put_env(:block_poker, :client_release, previous)
      Feed.reset()
    end)

    :ok
  end

  defp configure(opts), do: Application.put_env(:block_poker, :client_release, opts)

  test "сборка ниже минимума в игру не пускается" do
    configure(current: "1.4.2", minimum: "1.4.0")

    assert {:error, :client_too_old} = ClientReleases.check("1.3.9")
    assert {:error, :client_too_old} = ClientReleases.check("0.9.0")
  end

  test "сборка ровно на минимуме и выше пускается" do
    configure(current: "1.4.2", minimum: "1.4.0")

    assert :ok = ClientReleases.check("1.4.0")
    assert :ok = ClientReleases.check("1.4.2")
    assert :ok = ClientReleases.check("2.0.0")
  end

  test "версия сравнивается по semver, а не лексикографически" do
    configure(minimum: "1.9.0")

    assert :ok = ClientReleases.check("1.10.0")
    assert {:error, :client_too_old} = ClientReleases.check("1.8.0")
  end

  test "клиент новее минимума, но старее актуального — играет и знает про обновление" do
    configure(current: "1.4.2", minimum: "1.4.0")

    assert :ok = ClientReleases.check("1.4.1")
    assert ClientReleases.outdated?("1.4.1")
    refute ClientReleases.outdated?("1.4.2")
  end

  test "версия не передана — считается нулевой" do
    configure(minimum: "1.0.0")
    assert {:error, :client_too_old} = ClientReleases.check(nil)

    configure(minimum: "0.0.0")
    assert :ok = ClientReleases.check(nil)
  end

  test "мусор вместо версии гейт не обходит" do
    configure(minimum: "1.0.0")

    assert {:error, :client_too_old} = ClientReleases.check("не версия")
    assert {:error, :client_too_old} = ClientReleases.check("")
    assert {:error, :client_too_old} = ClientReleases.check(42)
  end

  test "ненастроенный минимум никого не отсекает" do
    configure([])

    assert :ok = ClientReleases.check("0.0.1")
    assert :ok = ClientReleases.check(nil)
  end

  test "битая граница в конфиге не превращается в массовый отказ" do
    configure(minimum: "мусор")

    assert :ok = ClientReleases.check("1.0.0")
  end

  test "info отдаёт обе границы и адрес фида" do
    configure(current: "1.4.2", minimum: "1.4.0", feed_url: "https://cdn/updates")

    assert ClientReleases.info() == %{
             current: "1.4.2",
             minimum: "1.4.0",
             feed_url: "https://cdn/updates/"
           }
  end

  # `electron-updater` разрешает имя файла относительно адреса фида через
  # `new URL/2`: без завершающего слеша последний сегмент отбрасывается, и
  # клиент уходит за `latest.yml` в корень хоста.
  test "адрес фида нормализуется до завершающего слеша" do
    configure(feed_url: "https://cdn/updates")
    assert ClientReleases.feed_url() == "https://cdn/updates/"

    configure(feed_url: "https://cdn/updates///")
    assert ClientReleases.feed_url() == "https://cdn/updates/"

    configure(feed_url: nil)
    assert ClientReleases.feed_url() == nil
  end
end
