defmodule Api.ClientUpdatesPlugTest do
  @moduledoc """
  Раздача файлов автообновления по `/client-updates`.

  Тест сквозной, через весь эндпоинт, а не поверх `Plug.Static`: сломать
  раздачу может и порядок плагов, и кэш опций в `:persistent_term`, и
  каталог, которого нет, — то есть ровно то, что при вызове плага
  напрямую не проверяется.
  """

  use Api.ConnCase, async: false

  @dir Path.expand("../../tmp/client_updates_plug", __DIR__)

  setup do
    File.rm_rf!(@dir)
    File.mkdir_p!(@dir)

    previous = Application.get_env(:block_poker, :client_release, [])

    Application.put_env(
      :block_poker,
      :client_release,
      Keyword.merge(previous, dir: @dir, feed_url: "https://cdn.example/client-updates")
    )

    on_exit(fn ->
      Application.put_env(:block_poker, :client_release, previous)
      :persistent_term.erase({Api.Plugs.ClientUpdates, @dir})
      File.rm_rf!(@dir)
    end)

    :ok
  end

  test "фид отдаётся по тому адресу, который клиент собирает из feed_url", %{conn: conn} do
    File.write!(Path.join(@dir, "latest.yml"), "version: 1.0.2\n")

    # Ровно тот путь, который получается из `new URL("latest.yml", feed_url)`
    # на стороне `electron-updater`.
    conn = get(conn, "/client-updates/latest.yml")

    assert conn.status == 200
    assert conn.resp_body == "version: 1.0.2\n"
  end

  test "инсталлятор отдаётся под своим именем", %{conn: conn} do
    File.write!(Path.join(@dir, "1.0.2_BlockPoker-setup.exe"), "MZ")

    conn = get(conn, "/client-updates/1.0.2_BlockPoker-setup.exe")

    assert conn.status == 200
    assert conn.resp_body == "MZ"
  end

  test "отсутствующий файл — 404, а не проваленный дальше запрос", %{conn: conn} do
    conn = get(conn, "/client-updates/latest.yml")

    assert conn.status == 404
  end
end
