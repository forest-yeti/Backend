defmodule Api.Plugs.BannerImages do
  @moduledoc """
  Раздача картинок баннеров по `/banners`.

  Обёртка над `Plug.Static` по тем же причинам, что и
  `Api.Plugs.ClientUpdates`: каталог задаётся окружением, а `Plug.Static`
  разбирает опции на компиляции. Разобранные опции кэшируются в
  `:persistent_term` — разбор один раз на каталог.

  Каталог не настроен — плаг прозрачен: картинки может раздавать nginx
  или CDN, и тогда бэкенд только хранит имена файлов и собирает адреса.
  """

  @behaviour Plug

  @at "/banners"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case static_opts() do
      nil -> conn
      opts -> Plug.Static.call(conn, opts)
    end
  end

  defp static_opts do
    case Application.get_env(:block_poker, :banners, [])[:dir] do
      dir when is_binary(dir) and dir != "" -> cached_opts(dir)
      _absent -> nil
    end
  end

  defp cached_opts(dir) do
    key = {__MODULE__, dir}

    case :persistent_term.get(key, nil) do
      nil ->
        opts =
          Plug.Static.init(
            at: @at,
            from: dir,
            gzip: false,
            # Имя файла содержит случайный суффикс и меняется при каждой
            # правке баннера, поэтому содержимое под конкретным адресом
            # неизменно и кэшируется надолго. Замену картинки клиент
            # увидит сразу: у неё уже другой адрес.
            cache_control_for_etags: "public, max-age=86400"
          )

        :persistent_term.put(key, opts)
        opts

      opts ->
        opts
    end
  end
end
