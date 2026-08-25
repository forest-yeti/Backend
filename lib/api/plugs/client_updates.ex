defmodule Api.Plugs.ClientUpdates do
  @moduledoc """
  Раздача файлов обновления клиента: `latest.yml` и инсталляторы.

  Обёртка над `Plug.Static`, а не сам `Plug.Static`, ровно по одной причине:
  каталог задаётся переменной окружения. `Plug.Static` разбирает опции на
  компиляции, а путь к папке со сборками известен только на конкретной ноде —
  в релизе это не `priv/`, а том, куда CI кладёт артефакты.

  Разобранные опции кэшируются в `:persistent_term`: разбор делается один
  раз на каталог, дальше плаг стоит столько же, сколько обычный `Plug.Static`.

  Каталог не настроен — плаг прозрачен: нода без раздачи обновлений это
  рабочее состояние (файлы может отдавать nginx или CDN, а бэкенд при этом
  по-прежнему сообщает версии через `GET /api/client/version`).
  """

  @behaviour Plug

  @at "/client-updates"

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
    case Application.get_env(:block_poker, :client_release, [])[:dir] do
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
            # `latest.yml` — точка входа автообновления, и он обязан
            # протухать быстро: иначе прокси игрока будет отдавать
            # позавчерашнюю версию уже после того, как вы выкатили новую.
            # Сами инсталляторы неизменяемы, но лежат под своими именами
            # с версией, так что общий короткий срок им ничего не стоит.
            cache_control_for_etags: "public, max-age=60"
          )

        :persistent_term.put(key, opts)
        opts

      opts ->
        opts
    end
  end
end
