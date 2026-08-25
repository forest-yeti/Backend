defmodule BlockPoker.ClientReleasesTest do
  @moduledoc """
  Уровень 3: сборки клиента на настоящей БД и настоящем диске.

  Файловая система здесь не мокается по той же причине, по которой не
  мокается MySQL: половина гарантий — это поведение реальных файловых
  операций (запись, подсчёт хэша, отсутствие файла). Мок проверял бы мок.
  Каталог на тест свой, `:client_release` подменяется целиком.
  """

  use BlockPoker.DataCase, async: false

  import BlockPoker.AdminFixtures

  alias BlockPoker.ClientReleases
  alias BlockPoker.ClientReleases.Feed

  setup do
    dir =
      Path.join(System.tmp_dir!(), "client_releases_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)

    previous = Application.get_env(:block_poker, :client_release, [])

    Application.put_env(:block_poker, :client_release,
      current: "0.0.0",
      minimum: "0.0.0",
      feed_url: "https://updates.example/client",
      dir: dir
    )

    Feed.reset()

    on_exit(fn ->
      Application.put_env(:block_poker, :client_release, previous)
      Feed.reset()
      File.rm_rf(dir)
    end)

    Map.merge(admin_with_ctx(), %{dir: dir})
  end

  defp installer(contents \\ "инсталлятор") do
    path = Path.join(System.tmp_dir!(), "upload_#{System.unique_integer([:positive])}.bin")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp upload!(ctx, version, opts \\ []) do
    {:ok, release} =
      ClientReleases.upload(ctx, %{
        version: version,
        mandatory: Keyword.get(opts, :mandatory, false),
        notes: Keyword.get(opts, :notes),
        path: installer(Keyword.get(opts, :contents, "инсталлятор #{version}")),
        original_name: Keyword.get(opts, :original_name, "BlockPoker-Setup.exe")
      })

    release
  end

  describe "загрузка" do
    test "кладёт файл на диск и считает sha512", %{ctx: ctx, dir: dir} do
      release = upload!(ctx, "1.0.0", contents: "содержимое")

      path = Path.join(dir, release.file_name)
      assert File.exists?(path)
      assert release.byte_size == byte_size("содержимое")
      assert release.sha512 == Base.encode64(:crypto.hash(:sha512, "содержимое"))
    end

    test "имя файла собирает сервер, а не приходящая строка", %{ctx: ctx, dir: dir} do
      release = upload!(ctx, "1.0.0", original_name: "../../злой файл.exe")

      assert String.starts_with?(release.file_name, "1.0.0_")
      assert String.ends_with?(release.file_name, ".exe")
      refute String.contains?(release.file_name, "/")
      refute String.contains?(release.file_name, "..")

      refute String.contains?(release.file_name, "\\")

      # Главное: файл лёг ровно в каталог сборок, а не выше по дереву.
      assert File.ls!(dir) == [release.file_name]
    end

    test "загруженная сборка на клиентов не влияет", %{ctx: ctx} do
      upload!(ctx, "1.0.0")

      assert ClientReleases.current() == "0.0.0"
      assert ClientReleases.info().current == "0.0.0"
    end

    test "версия не semver — отказ, файла не остаётся", %{ctx: ctx, dir: dir} do
      assert {:error, :invalid_version} =
               ClientReleases.upload(ctx, %{
                 version: "последняя",
                 path: installer(),
                 original_name: "setup.exe"
               })

      assert File.ls!(dir) == []
    end

    test "повтор версии отвергается", %{ctx: ctx} do
      upload!(ctx, "1.0.0")

      assert {:error, :version_exists} =
               ClientReleases.upload(ctx, %{
                 version: "1.0.0",
                 path: installer(),
                 original_name: "setup.exe"
               })
    end

    test "каталог не настроен — честная ошибка, а не тишина", %{ctx: ctx} do
      Application.put_env(:block_poker, :client_release, current: "0.0.0", minimum: "0.0.0")

      assert {:error, :updates_dir_not_configured} =
               ClientReleases.upload(ctx, %{
                 version: "1.0.0",
                 path: installer(),
                 original_name: "setup.exe"
               })
    end

    test "загрузка пишется в журнал действий", %{ctx: ctx} do
      release = upload!(ctx, "1.0.0")

      assert {:ok, %{entries: entries}} = BlockPoker.Admin.audit(ctx, %{})
      assert entry = Enum.find(entries, &(&1.action == :client_release_upload))
      assert entry.subject_type == :client_release
      assert entry.subject_id == release.id
    end
  end

  describe "публикация" do
    test "делает сборку актуальной и пишет latest.yml", %{ctx: ctx, dir: dir} do
      release = upload!(ctx, "1.0.1")

      assert {:ok, published} = ClientReleases.publish(ctx, release.id)
      assert published.published_at

      assert ClientReleases.current() == "1.0.1"

      feed = File.read!(Path.join(dir, "latest.yml"))
      assert feed =~ "version: 1.0.1"
      assert feed =~ "url: #{release.file_name}"
      assert feed =~ "sha512: #{release.sha512}"
      assert feed =~ "size: #{release.byte_size}"
    end

    test "обязательная сборка поднимает минимум", %{ctx: ctx} do
      release = upload!(ctx, "1.0.1", mandatory: true)
      {:ok, _published} = ClientReleases.publish(ctx, release.id)

      assert ClientReleases.minimum() == "1.0.1"
      assert {:error, :client_too_old} = ClientReleases.check("1.0.0")
      assert :ok = ClientReleases.check("1.0.1")
    end

    test "необязательная сборка минимум не трогает", %{ctx: ctx} do
      release = upload!(ctx, "1.0.1")
      {:ok, _published} = ClientReleases.publish(ctx, release.id)

      assert ClientReleases.minimum() == "0.0.0"
      assert :ok = ClientReleases.check("1.0.0")
      assert ClientReleases.outdated?("1.0.0")
    end

    test "актуальная — последняя опубликованная, а не наибольшая", %{ctx: ctx} do
      first = upload!(ctx, "1.0.1")
      second = upload!(ctx, "1.0.2")

      {:ok, _} = ClientReleases.publish(ctx, second.id)
      {:ok, _} = ClientReleases.publish(ctx, first.id)

      assert ClientReleases.current() == "1.0.1"
    end

    test "откат не запирает игроков минимумом от снятой сборки", %{ctx: ctx} do
      old = upload!(ctx, "1.0.0")
      new = upload!(ctx, "1.0.1", mandatory: true)

      {:ok, _} = ClientReleases.publish(ctx, new.id)
      {:ok, _} = ClientReleases.publish(ctx, old.id)

      assert ClientReleases.current() == "1.0.0"
      assert ClientReleases.minimum() == "0.0.0"
      assert :ok = ClientReleases.check("1.0.0")
    end

    test "сборка без файла на диске не публикуется", %{ctx: ctx, dir: dir} do
      release = upload!(ctx, "1.0.1")
      File.rm!(Path.join(dir, release.file_name))

      assert {:error, :release_file_missing} = ClientReleases.publish(ctx, release.id)
      refute File.exists?(Path.join(dir, "latest.yml"))
    end

    test "несуществующая сборка — not_found", %{ctx: ctx} do
      assert {:error, :not_found} = ClientReleases.publish(ctx, Ecto.UUID.generate())
      assert {:error, :not_found} = ClientReleases.publish(ctx, "не-uuid")
    end
  end

  describe "удаление" do
    test "черновик удаляется вместе с файлом", %{ctx: ctx, dir: dir} do
      release = upload!(ctx, "1.0.1")

      assert :ok = ClientReleases.delete(ctx, release.id)
      refute File.exists?(Path.join(dir, release.file_name))
      assert %{items: []} = ClientReleases.list()
    end

    test "опубликованную сборку удалить нельзя", %{ctx: ctx, dir: dir} do
      release = upload!(ctx, "1.0.1")
      {:ok, _published} = ClientReleases.publish(ctx, release.id)

      assert {:error, :release_published} = ClientReleases.delete(ctx, release.id)
      assert File.exists?(Path.join(dir, release.file_name))
    end
  end

  describe "список" do
    test "свежие первыми, с признаком наличия файла", %{ctx: ctx, dir: dir} do
      upload!(ctx, "1.0.0")
      second = upload!(ctx, "1.0.1")

      File.rm!(Path.join(dir, second.file_name))

      assert %{items: [newer, older], current: "0.0.0", minimum: "0.0.0"} =
               ClientReleases.list()

      assert newer.version == "1.0.1"
      assert older.version == "1.0.0"
      refute newer.file_present
      assert older.file_present
    end
  end
end
