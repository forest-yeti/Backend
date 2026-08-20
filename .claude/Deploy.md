# Деплой Block Poker на VPS

Пошаговая инструкция для развёртывания бэкенда на чистой Ubuntu.
Всё, что здесь описано, выполняет `deploy/ubuntu.sh` — документ объясняет,
что происходит и как этим управлять.

---

## Этап 0. Что понадобится

- **VDS** с чистой Ubuntu 22.04 или 24.04. Минимум — 2 vCPU и 2 ГБ RAM: сборка
  релиза компилирует Erlang-код и C-NIF, на 1 ГБ она упирается в OOM. Диска
  хватит 20 ГБ.
- **SSH-доступ** — root или пользователь с sudo.
- **Репозиторий** должен быть доступен с сервера, либо исходники заливаются вручную.

Домен покупать не нужно. Заранее выберите режим:

| Режим | Адрес клиента | Когда |
|---|---|---|
| Свой домен | `wss://poker.example.com` | есть домен, боевой запуск |
| **sslip.io** (по умолчанию) | `wss://203-0-113-45.sslip.io` | домена нет, но нужен нормальный TLS |
| Голый IP без TLS | `ws://203.0.113.45` | стенд для отладки |

По умолчанию скрипт делает второй вариант.

### Про sslip.io

`sslip.io` резолвит любое имя вида `203-0-113-45.sslip.io` в адрес `203.0.113.45`.
Регистрировать ничего не надо, а поскольку домен входит в Public Suffix List,
Let's Encrypt выдаёт на него обычный доверенный сертификат. Это способ получить
настоящий TLS, имея на руках только IP.

---

## Этап 1. Подготовить сервер

Создайте VDS, образ **Ubuntu 24.04 LTS**, добавьте SSH-ключ. Запишите публичный IP.

Если используете свой домен — заведите A-запись:

```
poker.example.com.   A   203.0.113.45
```

Дайте DNS 10–15 минут и проверьте `nslookup poker.example.com`. Без этого упадёт
выпуск сертификата.

### Подключение

Удобно завести алиас в `~/.ssh/config` (на Windows — `C:\Users\<вы>\.ssh\config`):

```
Host nl-dev
    HostName 148.135.209.23
    User nl-develop
    IdentityFile ~/.ssh/id_ed25519_forest_yeti
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 4
```

`IdentitiesOnly yes` обязателен, если в `~/.ssh` лежит несколько ключей: без него
ssh предложит серверу все подряд и может упереться в лимит попыток аутентификации.

На Windows приватному ключу нужно урезать права, иначе OpenSSH откажется его
использовать:

```powershell
icacls "$env:USERPROFILE\.ssh\id_ed25519_forest_yeti" /inheritance:r
icacls "$env:USERPROFILE\.ssh\id_ed25519_forest_yeti" /grant:r "$($env:USERNAME):(R)"
```

Дальше — `ssh nl-dev`.

> **Корпоративная сеть.** `ssh.exe` не читает `HTTP_PROXY`/`NO_PROXY` и всегда
> идёт напрямую. Если исходящий 22-й порт закрыт периметром, нужен либо
> `ProxyCommand` через корпоративный прокси (`connect.exe` из состава Git for
> Windows), либо правило на прокси, разрешающее `CONNECT` на `<ip>:22`.

---

## Этап 2. Доставить исходники

### Вариант А — клонировать на сервере

```bash
sudo apt update && sudo apt install -y git
sudo mkdir -p /opt/block_poker
sudo chown "$USER" /opt/block_poker
git clone <адрес-репозитория> /opt/block_poker/src
cd /opt/block_poker/src
```

### Вариант Б — залить со своей машины

В PowerShell из корня проекта:

```powershell
scp -r -O . nl-dev:~/block-poker-src
```

Затем на сервере:

```bash
sudo mkdir -p /opt/block_poker
sudo mv ~/block-poker-src /opt/block_poker/src
cd /opt/block_poker/src
```

`_build` и `deps` переносить не нужно — они пересобираются на месте, потому что
`argon2_elixir` это NIF на C и виндовая сборка на Linux не работает.

---

## Этап 3. Запустить скрипт

Один из трёх вариантов (под root или через sudo):

```bash
# домена нет — адрес будет <ip>.sslip.io, TLS настоящий
sudo -E bash deploy/ubuntu.sh

# свой домен
sudo -E env DOMAIN=poker.example.com EMAIL=admin@example.com bash deploy/ubuntu.sh

# голый IP, без шифрования (только стенд)
sudo -E env ALLOW_PLAIN_HTTP=1 bash deploy/ubuntu.sh
```

Первый прогон занимает **8–15 минут** — почти всё время уходит на компиляцию
зависимостей и NIF. Скрипт печатает зелёные заголовки шагов; при падении
сообщает номер строки, и его можно запускать заново — он идемпотентен.

### Переменные

| Переменная | Смысл |
|---|---|
| `DOMAIN` | домен с готовой A-записью. Не задан → `<публичный-ip>.sslip.io` |
| `EMAIL` | почта для Let's Encrypt (без неё не будет писем об истечении) |
| `ALLOW_PLAIN_HTTP=1` | собрать без `force_ssl`, работать по `http://` |
| `SKIP_TLS=1` | не выпускать сертификат |
| `REPO_URL` / `REPO_REF` | тянуть исходники из git вместо каталога рядом |
| `APP_USER` | системный пользователь (по умолчанию `blockpoker`) |
| `BASE_DIR` | корень установки (по умолчанию `/opt/block_poker`) |
| `ELIXIR_VERSION` | версия Elixir (по умолчанию `1.18.4`) |

### Что происходит внутри

1. **Проверки и выбор адреса.** Если `DOMAIN` не задан, определяется публичный IP
   и собирается имя `<ip>.sslip.io`.
2. **Системные пакеты**: build-essential, git, MySQL 8, nginx, ufw.
3. **Erlang/OTP 27** — три пути по убыванию скорости: репозиторий Erlang
   Solutions → пакеты Ubuntu → сборка из исходников. Версия обязательно
   проверяется: Elixir 1.17+ требует минимум OTP 25, а в репозитории Ubuntu
   22.04 лежит OTP 24, под который сборок Elixir просто нет. На 22.04 дело
   почти наверняка дойдёт до сборки из исходников — это 15–25 минут.
4. **Elixir 1.18.4** — готовой сборкой с GitHub, подобранной под установленный OTP.
5. **Пользователь `blockpoker`**, домашний каталог `/opt/block_poker`.
6. **MySQL**: база `` `block-poker` ``, пользователь `blockpoker`, случайный пароль.
7. **`/etc/block_poker.env`** (права 0600) — `SECRET_KEY_BASE`, `DATABASE_URL`,
   `PHX_HOST`, `PORT`. Ровно те переменные, которые читает `config/runtime.exs`.
8. **Сборка релиза** под пользователем `blockpoker` в `/opt/block_poker/current`.
9. **Миграции** — `BlockPoker.Release.migrate()`.
10. **Сид сетки лимитов** — `BlockPoker.Release.seed_cash_games()`. Без него
    `cash_game_settings` пустая, а значит и лобби пустое.
11. **systemd-юнит `block-poker`** с `LimitNOFILE=65536` и `TimeoutStopSec=30`.
12. **nginx** — `map $http_upgrade`, `proxy_read_timeout 3600s` на `/socket/`,
    `X-Forwarded-Proto` везде.
13. **ufw** (22, 80, 443) и **сертификат Let's Encrypt** с автопродлением.

---

## Этап 4. Проверить, что живо

```bash
systemctl status block-poker          # должно быть active (running)
curl https://<адрес>/health           # healthcheck
journalctl -u block-poker -n 50       # последние строки лога
```

Грубая проверка сокета — сервер должен ответить `400`, а не `502`:

```bash
curl -i https://<адрес>/socket/websocket
```

`502 Bad Gateway` значит, что nginx жив, а приложение нет: смотрите `journalctl`.

---

## Этап 5. Завести первого пользователя

Регистрация идёт по HTTP, потому что соединения ещё нет:

```bash
curl -X POST https://<адрес>/api/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"email":"you@example.com","password":"...","name":"You"}'
```

Учтите rate limit: 10 попыток на `/api/auth/register` и `/login` за 5 минут.

### Роль администратора

Через сокет роль не выдаётся принципиально — только с сервера. В релизе
`mix user.role` недоступен, поэтому через удалённую консоль:

```bash
sudo -u blockpoker HOME=/opt/block_poker \
  /opt/block_poker/current/bin/block_poker remote
```

```elixir
{:ok, user} = BlockPoker.Accounts.find_user("you@example.com")
BlockPoker.Accounts.set_role(user, "admin")
```

Выход из консоли — `Ctrl+C` дважды. Это отцепит консоль, сервер продолжит работать.

---

## Этап 6. Подключить клиент

Адреса печатает сам скрипт в конце:

```
POST  https://203-0-113-45.sslip.io/api/auth/login
WS    wss://203-0-113-45.sslip.io/socket/websocket?token=<из ответа login>&vsn=2.0.0
```

В `config/runtime.exs` для прода стоит `check_origin: false`. Без этого Electron
не подключился бы: он присылает `Origin: file://`, и штатная проверка Phoenix
отвергала бы handshake. Это безопасно — соединение авторизуется явным
socket-токеном, а не куками, поэтому CSRF-риска нет.

---

## Этап 7. Эксплуатация

```bash
journalctl -u block-poker -f                    # живой лог
systemctl restart block-poker                   # рестарт
systemctl stop block-poker                      # остановка
cat /etc/block_poker.env                        # пароль БД и SECRET_KEY_BASE

sudo -u blockpoker HOME=/opt/block_poker \
  /opt/block_poker/current/bin/block_poker remote   # консоль на живой ноде
```

> **Про рестарт.** По §8 CLAUDE.md перезапуск гасит все `TableServer`:
> незавершённые раздачи аннулируются, ставки возвращаются из снапшота стеков.
> Рестартуйте в окно низкой активности.

### Правка лимитов кэш-игры

Строки `cash_game_settings` правятся прямо в БД. Лобби перечитывает их раз в
минуту; подтолкнуть можно из консоли:

```elixir
BlockPoker.Tables.Lobby.reload()
```

### Бэкап базы

Имя базы с дефисом, поэтому в кавычках:

```bash
mysqldump --single-transaction --databases 'block-poker' \
  | gzip > /root/block-poker-$(date +%F).sql.gz
```

Ставьте в cron ежедневно. Ценное здесь — `wallet_entries` (append-only ledger по
деньгам) и `hands` / `hand_actions` (история раздач). Игровое состояние в БД не
живёт и бэкапу не подлежит.

---

## Этап 8. Обновление

Тот же скрипт. Он переиспользует уже сгенерированные пароль и `SECRET_KEY_BASE`,
не пересоздаёт базу, не перевыпускает сертификат — только подтягивает код,
пересобирает релиз, накатывает новые миграции и перезапускает сервис.

```bash
cd /opt/block_poker/src
git pull
sudo -E bash deploy/ubuntu.sh
```

С `REPO_URL` скрипт сам сделает `fetch` и `reset --hard` на нужную ветку:

```bash
sudo -E env REPO_URL=<адрес> REPO_REF=master bash deploy/ubuntu.sh
```

Повторные прогоны быстрые — 1–2 минуты, зависимости уже собраны.

---

## Траблшутинг

| Симптом | Причина | Что делать |
|---|---|---|
| `certbot не справился` | A-запись не смотрит на сервер, или 80-й порт закрыт файрволом провайдера | Проверить `nslookup`, открыть 80 в панели провайдера, запустить скрипт заново |
| `502 Bad Gateway` | приложение упало или не стартовало | `journalctl -u block-poker -n 100` |
| Сборка падает без внятной ошибки | не хватило памяти | `fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile` |
| `Не скачался ... elixir-otp-24.zip` | встал OTP 24 из репозитория Ubuntu 22.04 | Обновите скрипт: он теперь проверяет версию и при необходимости собирает OTP 27 из исходников |
| `Сборка OTP не удалась` | не хватило памяти на компиляции Erlang | Добавить swap (см. строку ниже) и запустить заново |
| Сокет рвётся примерно раз в минуту | правился конфиг nginx и потерялись таймауты | Вернуть `proxy_read_timeout 3600s` в `location /socket/` |
| Лобби пустое | не прошёл сид | `sudo -u blockpoker /opt/block_poker/current/bin/block_poker eval "BlockPoker.Release.seed_cash_games()"` |
| Клиент не подключается, в логе отказ на handshake | несовпадение версии протокола или просроченный токен | Сверить `vsn`, получить свежий токен через `/api/auth/login` |
| `ssh` таймаутит | закрыт исходящий 22-й порт в корпоративной сети | Проверить с мобильной раздачи; при подтверждении — `ProxyCommand` или правило на прокси |

---

## Открытые хвосты

- `Oban` числится в зависимостях, но не сконфигурирован и не в дереве
  супервизоров. Деплою не мешает; если на нём планировались выплаты и отложенные
  списания — это отдельная задача.
- Скрипт проверен на синтаксис, оба режима `config/prod.exs` прогнаны через
  `Config.Reader`. Первый прогон стоит делать на одноразовой машине.
