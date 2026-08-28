defmodule BlockPoker.Sounds.Storage do
  @moduledoc """
  Звуковые файлы на диске.

  Устроено ровно как `BlockPoker.Banners.Storage`: каталог задаётся
  окружением (`:sounds, :dir`), раздаётся статикой по `/sounds`, без
  настроенного каталога загрузка — честная ошибка, а не запись в никуда.

  Формат проверяется **по содержимому**: расширение и `content-type`
  пишет клиент, а играть у игрока будет то, что реально легло на диск.
  Распознанная сигнатура же и даёт расширение имени — так `.mp3` в
  каталоге всегда означает MP3.
  """

  import Bitwise, only: [band: 2]

  # 5 МБ. Звук в игровой комнате — это короткий эффект или фраза, а не
  # трек; жёсткий предел тела стоит в `Api.Plugs.SoundUpload`, этот —
  # доменный, и он сообщает осмысленный код вместо обрыва разбора.
  @max_bytes 5 * 1024 * 1024

  @doc "Каталог со звуками или `nil`, если раздача не настроена."
  @spec dir() :: String.t() | nil
  def dir do
    case config()[:dir] do
      dir when is_binary(dir) and dir != "" -> dir
      _absent -> nil
    end
  end

  @doc """
  Полный адрес файла для клиента.

  База — из конфигурации, а не из `conn`: тот же ответ уходит и через
  прокси, и напрямую. Базы нет — путь от корня, клиент разрешит его
  относительно адреса API.
  """
  @spec url(String.t()) :: String.t()
  def url(file_name) do
    case config()[:base_url] do
      base when is_binary(base) and base != "" ->
        String.trim_trailing(base, "/") <> "/" <> file_name

      _absent ->
        "/sounds/" <> file_name
    end
  end

  @doc """
  Кладёт загруженный файл в каталог.

  Имя — случайное, а не производное от названия звука: название пишет
  человек, оно бывает кириллическим и с пробелами, а имя файла уходит в
  URL. Заодно снимается вопрос коллизий при одинаковых названиях.
  """
  @spec store(String.t()) ::
          {:ok, %{file: String.t(), bytes: pos_integer(), format: String.t()}} | {:error, atom()}
  def store(source_path) do
    with {:ok, dir} <- ensure_dir(),
         {:ok, bytes} <- ensure_size(source_path),
         {:ok, format} <- ensure_audio(source_path) do
      file_name = "#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}.#{format}"

      case File.cp(source_path, Path.join(dir, file_name)) do
        :ok -> {:ok, %{file: file_name, bytes: bytes, format: format}}
        {:error, _reason} -> {:error, :upload_write_failed}
      end
    end
  end

  @doc "Удаляет файл. Отсутствие файла ошибкой не считается."
  @spec delete(String.t() | nil) :: :ok
  def delete(nil), do: :ok

  def delete(file_name) do
    case dir() do
      nil -> :ok
      dir -> dir |> Path.join(file_name) |> File.rm() |> ignore_missing()
    end
  end

  defp config, do: Application.get_env(:block_poker, :sounds, [])

  defp ensure_dir do
    case dir() do
      nil ->
        {:error, :sounds_dir_not_configured}

      dir ->
        case File.mkdir_p(dir) do
          :ok -> {:ok, dir}
          {:error, _reason} -> {:error, :sounds_dir_not_configured}
        end
    end
  end

  defp ensure_size(path) do
    case File.stat(path) do
      {:ok, %{size: 0}} -> {:error, :empty_upload}
      {:ok, %{size: size}} when size > @max_bytes -> {:error, :audio_too_large}
      {:ok, %{size: size}} -> {:ok, size}
      {:error, _reason} -> {:error, :upload_write_failed}
    end
  end

  # Сигнатуры, а не расширения. У MP3 их две: файл с тегами начинается с
  # `ID3`, файл без тегов — сразу с кадра, у которого выставлены
  # одиннадцать старших бит синхрослова.
  defp ensure_audio(path) do
    case File.read(path) do
      {:ok, <<"OggS", _rest::binary>>} -> {:ok, "ogg"}
      {:ok, <<"RIFF", _size::binary-size(4), "WAVE", _rest::binary>>} -> {:ok, "wav"}
      {:ok, <<"ID3", _rest::binary>>} -> {:ok, "mp3"}
      {:ok, <<0xFF, second, _rest::binary>>} when band(second, 0xE0) == 0xE0 -> {:ok, "mp3"}
      {:ok, _other} -> {:error, :unsupported_audio_type}
      {:error, _reason} -> {:error, :upload_write_failed}
    end
  end

  defp ignore_missing(_result), do: :ok
end
