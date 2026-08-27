defmodule BlockPoker.Banners.Storage do
  @moduledoc """
  Картинки баннеров на диске.

  Устроено по образцу `BlockPoker.ClientReleases.Storage`: каталог задаётся
  окружением (`:banners, :dir`), раздаётся статикой по `/banners`, и без
  настроенного каталога загрузка — честная ошибка, а не запись в никуда.

  Тип файла проверяется **по содержимому**, а не по расширению и не по
  `content-type` из формы: и то, и другое пишет клиент, а на диск и в
  раздачу попадает то, что реально пришло. Расширение имени на диске
  выводится из распознанной сигнатуры — так `.png` в каталоге всегда
  означает PNG.
  """

  # 5 МБ — заведомо больше любого разумного баннера и заведомо меньше
  # того, чем можно забить диск. Жёсткий предел тела стоит в
  # `Api.Plugs.BannerUpload`, этот — доменный, и он же сообщает
  # осмысленный код ошибки вместо обрыва разбора тела.
  @max_bytes 5 * 1024 * 1024

  @doc "Каталог с картинками или `nil`, если раздача не настроена."
  @spec dir() :: String.t() | nil
  def dir do
    case config()[:dir] do
      dir when is_binary(dir) and dir != "" -> dir
      _absent -> nil
    end
  end

  @doc """
  Полный адрес картинки для клиента.

  Базовый адрес отдаётся из конфигурации, а не собирается из `conn`: тот
  же ответ уходит и через прокси, и напрямую, и заголовки запроса тут не
  источник истины. Базы нет — отдаём путь от корня: клиент разрешит его
  относительно того адреса API, на который и так ходит.
  """
  @spec url(String.t()) :: String.t()
  def url(file_name) do
    case config()[:base_url] do
      base when is_binary(base) and base != "" ->
        String.trim_trailing(base, "/") <> "/" <> file_name

      _absent ->
        "/banners/" <> file_name
    end
  end

  @doc """
  Кладёт загруженную картинку в каталог под именем, производным от места.

  Имя содержит случайный суффикс: файл заменяется при каждой правке, а
  под тем же именем его отдавал бы кэш браузера и прокси ещё сутки.
  """
  @spec store(String.t(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def store(source_path, place) do
    with {:ok, dir} <- ensure_dir(),
         :ok <- ensure_size(source_path),
         {:ok, ext} <- ensure_image(source_path) do
      file_name =
        "#{place}-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}.#{ext}"

      case File.cp(source_path, Path.join(dir, file_name)) do
        :ok -> {:ok, file_name}
        {:error, _reason} -> {:error, :upload_write_failed}
      end
    end
  end

  @doc "Удаляет картинку. Отсутствие файла ошибкой не считается."
  @spec delete(String.t() | nil) :: :ok
  def delete(nil), do: :ok

  def delete(file_name) do
    case dir() do
      nil -> :ok
      dir -> dir |> Path.join(file_name) |> File.rm() |> ignore_missing()
    end
  end

  defp config, do: Application.get_env(:block_poker, :banners, [])

  defp ensure_dir do
    case dir() do
      nil ->
        {:error, :banners_dir_not_configured}

      dir ->
        case File.mkdir_p(dir) do
          :ok -> {:ok, dir}
          {:error, _reason} -> {:error, :banners_dir_not_configured}
        end
    end
  end

  defp ensure_size(path) do
    case File.stat(path) do
      {:ok, %{size: 0}} -> {:error, :empty_upload}
      {:ok, %{size: size}} when size > @max_bytes -> {:error, :image_too_large}
      {:ok, %{size: _size}} -> :ok
      {:error, _reason} -> {:error, :upload_write_failed}
    end
  end

  # Сигнатуры, а не расширения: имя файла приходит от клиента.
  defp ensure_image(path) do
    case File.read(path) do
      {:ok, <<0x89, "PNG\r\n", 0x1A, "\n", _rest::binary>>} -> {:ok, "png"}
      {:ok, <<0xFF, 0xD8, 0xFF, _rest::binary>>} -> {:ok, "jpg"}
      {:ok, <<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>} -> {:ok, "webp"}
      {:ok, <<"GIF8", _rest::binary>>} -> {:ok, "gif"}
      {:ok, _other} -> {:error, :unsupported_image_type}
      {:error, _reason} -> {:error, :upload_write_failed}
    end
  end

  defp ignore_missing(_result), do: :ok
end
