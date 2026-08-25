# Сборки клиента

Сюда `electron-builder` кладёт артефакты релиза: инсталляторы и `latest.yml`.
Каталог раздаётся по `/client-updates` (`Api.Plugs.ClientUpdates`), путь
задаётся `:client_release, :dir` — в проде это `CLIENT_UPDATES_DIR`.

Содержимое в git не хранится: `.gitignore` рядом.
