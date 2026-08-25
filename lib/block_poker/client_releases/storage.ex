defmodule BlockPoker.ClientReleases.Storage do
  @moduledoc """
  Файлы сборок на диске: приём загруженного инсталлятора, подсчёт
  контрольной суммы и запись фида `latest.yml`.

  Каталог тот же, что раздаётся по `/client-updates`
  (`:client_release, :dir`). Если он не настроен — загрузка невозможна,
  и это честная ошибка, а не молчаливое «сохранили в никуда».

  Хэш считается **потоково**: инсталлятор весит сотни мегабайт, и читать
  его в память целиком ради `:crypto.hash/2` незачем.
  """

  @chunk 1024 * 1024

  @doc "Каталог со сборками или `nil`, если раздача не настроена."
  @spec dir() :: String.t() | nil
  def dir do
    case Application.get_env(:block_poker, :client_release, [])[:dir] do
      dir when is_binary(dir) and dir != "" -> dir
      _absent -> nil
    end
  end

  @doc """
  Кладёт загруженный файл в каталог сборок под именем `file_name`.

  Возвращает размер и sha512 в base64 — в том виде, в каком их ждёт
  `electron-updater`.
  """
  @spec store(String.t(), String.t()) ::
          {:ok, %{byte_size: pos_integer(), sha512: String.t()}} | {:error, atom()}
  def store(source_path, file_name) do
    with {:ok, dir} <- ensure_dir(),
         target = Path.join(dir, file_name),
         :ok <- copy(source_path, target),
         {:ok, %{size: size}} when size > 0 <- File.stat(target) do
      {:ok, %{byte_size: size, sha512: sha512(target)}}
    else
      {:error, reason} -> {:error, reason}
      # Файл нулевого размера — оборванная загрузка, а не релиз.
      {:ok, %File.Stat{}} -> {:error, :empty_upload}
    end
  end

  @doc "Удаляет файл сборки. Отсутствие файла ошибкой не считается."
  @spec delete(String.t()) :: :ok
  def delete(file_name) do
    case dir() do
      nil -> :ok
      dir -> dir |> Path.join(file_name) |> File.rm() |> ignore_missing()
    end
  end

  @doc "Есть ли файл сборки на диске — панель показывает это отдельным признаком."
  @spec exists?(String.t()) :: boolean()
  def exists?(file_name) do
    case dir() do
      nil -> false
      dir -> dir |> Path.join(file_name) |> File.regular?()
    end
  end

  @doc """
  Перезаписывает `latest.yml` под опубликованный релиз.

  Файл пишется через временный и переименованием: `electron-updater`
  читает фид в произвольный момент, и застать его наполовину записанным
  он не должен.
  """
  @spec write_feed(map()) :: :ok | {:error, atom()}
  def write_feed(%{version: version, file_name: file_name, byte_size: size, sha512: sha512}) do
    with {:ok, dir} <- ensure_dir() do
      body = """
      version: #{version}
      files:
        - url: #{file_name}
          sha512: #{sha512}
          size: #{size}
      path: #{file_name}
      sha512: #{sha512}
      releaseDate: '#{DateTime.utc_now() |> DateTime.to_iso8601()}'
      """

      target = Path.join(dir, "latest.yml")
      temp = target <> ".tmp"

      with :ok <- File.write(temp, body),
           :ok <- File.rename(temp, target) do
        :ok
      else
        {:error, _reason} -> {:error, :feed_write_failed}
      end
    end
  end

  defp ensure_dir do
    case dir() do
      nil ->
        {:error, :updates_dir_not_configured}

      dir ->
        case File.mkdir_p(dir) do
          :ok -> {:ok, dir}
          {:error, _reason} -> {:error, :updates_dir_not_configured}
        end
    end
  end

  # `File.cp/2`, а не `File.rename/2`: временный файл Plug лежит в системном
  # каталоге, который может оказаться на другом томе — там переименование
  # не работает вовсе.
  defp copy(source, target) do
    case File.cp(source, target) do
      :ok -> :ok
      {:error, _reason} -> {:error, :upload_write_failed}
    end
  end

  defp sha512(path) do
    path
    |> File.stream!(@chunk)
    |> Enum.reduce(:crypto.hash_init(:sha512), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode64()
  end

  defp ignore_missing(:ok), do: :ok
  defp ignore_missing({:error, :enoent}), do: :ok
  defp ignore_missing({:error, _reason}), do: :ok
end
