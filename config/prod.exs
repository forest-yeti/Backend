import Config

# Принудительный HTTPS. Заодно ставит HSTS.
# `:force_ssl` читается на этапе компиляции, поэтому переключатель — переменная
# окружения сборки, а не рантайма.
#
# `BLOCK_POKER_ALLOW_PLAIN_HTTP=1` собирает релиз без принуждения к TLS. Это
# нужно ровно для одного сценария — деплой на голый IP, где сертификат выпустить
# не у кого. Режим небезопасный: пароли и socket-токены пойдут по сети открытым
# текстом. Штатный путь — любое доменное имя (годится и бесплатное `sslip.io`).
if System.get_env("BLOCK_POKER_ALLOW_PLAIN_HTTP") in ~w(1 true) do
  IO.puts(:stderr, """
  [!] Релиз собирается БЕЗ force_ssl (BLOCK_POKER_ALLOW_PLAIN_HTTP).
      Трафик, включая пароли и socket-токены, не шифруется.
  """)
else
  config :block_poker, Socket.Endpoint,
    force_ssl: [
      rewrite_on: [:x_forwarded_proto],
      exclude: [
        paths: ["/health"],
        hosts: ["localhost", "127.0.0.1"]
      ]
    ]
end

# Наблюдение за столами из панели (god-mode).
#
# Включено осознанно, вопреки умолчанию из `config.exs`. Режим отдаёт все
# карманные карты всех игроков в реальном времени, поэтому по умолчанию он
# закрыт, и это остаётся верным: доступ к нему даёт не эта строка, а
# админский токен и роль, которые проверяются на каждом `join`.
#
# Пока рум обкатывается, разбор жалобы «у меня забрали банк» без открытого
# стола превращается в чтение `hand_actions` руками. Перед публичным
# релизом флаг возвращается в `false` вместе с вырезанием самого режима
# (§13 задачи 8).
config :block_poker, :admin_observer, enabled: true

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
