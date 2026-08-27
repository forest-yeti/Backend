#!/usr/bin/env bash
#
# Block Poker — развёртывание на чистой Ubuntu 22.04 / 24.04 одним прогоном.
#
# Ставит Erlang/Elixir, MySQL, nginx с TLS, собирает релиз, накатывает
# миграции, засевает сетку лимитов и поднимает systemd-юнит.
#
# Запуск (из корня склонированного репозитория, от root):
#
#     # свой домен
#     DOMAIN=poker.example.com EMAIL=admin@example.com bash deploy/ubuntu.sh
#
#     # только IP, домена нет — берётся <ip>.sslip.io и настоящий TLS
#     bash deploy/ubuntu.sh
#
#     # только IP и совсем без TLS (отладка, трафик открытым текстом)
#     ALLOW_PLAIN_HTTP=1 bash deploy/ubuntu.sh
#
# Скрипт идемпотентен: повторный прогон обновляет релиз и перезапускает
# сервис, не трогая базу, пароли и сертификат. Именно так и деплоятся
# обновления.
#
# Переменные окружения:
#   DOMAIN            домен, на который уже смотрит A-запись. Если не задан —
#                     подставляется <публичный-ip>.sslip.io
#   EMAIL             почта для Let's Encrypt (без неё сертификат выпускается
#                     без контакта — не будет писем об истечении)
#   ALLOW_PLAIN_HTTP=1  собрать без force_ssl и работать по http:// на голом IP.
#                     Небезопасно: пароли и токены идут открытым текстом.
#   REPO_URL          если задан — исходники клонируются отсюда, а не берутся
#                     из каталога рядом со скриптом
#   REPO_REF          ветка/тег для клона (по умолчанию master)
#   APP_USER          системный пользователь (по умолчанию blockpoker)
#   BASE_DIR          корень установки (по умолчанию /opt/block_poker)
#   ELIXIR_VERSION    версия Elixir (по умолчанию 1.18.4)
#   ERLANG_VERSION    версия OTP для сборки из исходников (по умолчанию 27.2.4);
#                     используется, только если готовых пакетов нужной версии нет
#   SKIP_TLS=1        не выпускать сертификат

set -Eeuo pipefail

APP_USER="${APP_USER:-blockpoker}"
BASE_DIR="${BASE_DIR:-/opt/block_poker}"
SRC_DIR="$BASE_DIR/src"
REL_DIR="$BASE_DIR/current"
ENV_FILE="/etc/block_poker.env"
UPDATES_DIR="${UPDATES_DIR:-$BASE_DIR/client_updates}"
DB_NAME="block-poker"
DB_USER="blockpoker"
ELIXIR_VERSION="${ELIXIR_VERSION:-1.18.4}"
ERLANG_VERSION="${ERLANG_VERSION:-27.2.4}"
REPO_REF="${REPO_REF:-master}"
SERVICE="block-poker"

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

trap 'die "Прервано на строке $LINENO. Скрипт можно перезапустить — он идемпотентен."' ERR

# --------------------------------------------------------------------------
# 0. Проверки
# --------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || die "Запускать от root: sudo -E bash deploy/ubuntu.sh"
command -v apt-get >/dev/null || die "Скрипт рассчитан на Ubuntu/Debian"

apt-get install -y -qq curl >/dev/null 2>&1 || true

detect_public_ip() {
  local ip
  for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip="$(curl -fsS --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]')" || continue
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { echo "$ip"; return 0; }
  done
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { echo "$ip"; return 0; }
  return 1
}

PLAIN_HTTP="${ALLOW_PLAIN_HTTP:-0}"

if [[ -z "${DOMAIN:-}" ]]; then
  PUBLIC_IP="$(detect_public_ip)" || die "Не определился публичный IP — задайте DOMAIN или IP=x.x.x.x"

  if [[ "$PLAIN_HTTP" == "1" ]]; then
    # Голый IP без TLS. Домена нет, сертификата нет, шифрования нет.
    DOMAIN="$PUBLIC_IP"
  else
    # sslip.io резолвит любое имя вида 1-2-3-4.sslip.io в 1.2.3.4. Регистрация
    # не нужна, домен в Public Suffix List, поэтому Let's Encrypt выдаёт на него
    # обычный доверенный сертификат. Это способ получить TLS, имея только IP.
    DOMAIN="${PUBLIC_IP//./-}.sslip.io"
    log "DOMAIN не задан — беру $DOMAIN (публичный IP $PUBLIC_IP через sslip.io)"
  fi
fi

if [[ "$PLAIN_HTTP" == "1" ]]; then
  warn "ALLOW_PLAIN_HTTP=1: релиз будет собран без force_ssl."
  warn "Пароли и socket-токены пойдут по сети открытым текстом. Только для отладки."
  export BLOCK_POKER_ALLOW_PLAIN_HTTP=1
  SKIP_TLS=1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_SRC="$(dirname "$SCRIPT_DIR")"

if [[ -z "${REPO_URL:-}" && ! -f "$LOCAL_SRC/mix.exs" ]]; then
  die "Рядом со скриптом нет mix.exs. Запустите его из репозитория или задайте REPO_URL."
fi

export DEBIAN_FRONTEND=noninteractive

# --------------------------------------------------------------------------
# 1. Системные пакеты
# --------------------------------------------------------------------------

log "Ставлю системные пакеты"
apt-get update -qq
apt-get install -y -qq \
  build-essential git curl unzip ca-certificates gnupg \
  libssl-dev libncurses-dev \
  mysql-server \
  nginx \
  ufw

# --------------------------------------------------------------------------
# 2. Erlang/OTP
# --------------------------------------------------------------------------

# Elixir 1.17+ требует минимум OTP 25. На Ubuntu 22.04 в репозитории лежит
# OTP 24 — под него сборок Elixir просто нет, поэтому версию обязательно
# проверяем, а не полагаемся на факт наличия `erl`.
MIN_OTP=25

mem_gb() {
  awk '/MemTotal/ { printf "%d", $2 / 1024 / 1024 }' /proc/meminfo
}

# Каждая параллельная задача компиляции съедает 300–500 МБ. На маленьком VDS
# `make -j$(nproc)` — это верный OOM, поэтому потоки ограничены и памятью тоже.
build_jobs() {
  local cpus mem jobs
  cpus="$(nproc)"
  mem="$(mem_gb)"
  jobs="$cpus"
  [[ "$mem" -lt "$cpus" ]] && jobs="$mem"
  [[ "$jobs" -lt 1 ]] && jobs=1
  echo "$jobs"
}

# Сборка Erlang и Elixir-кода на 2 ГБ без подкачки падает по OOM. Заводим swap
# сами, чтобы это не приходилось помнить руками.
ensure_swap() {
  local mem
  mem="$(mem_gb)"

  [[ "$mem" -ge 3 ]] && return
  [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]] && return

  log "На машине ${mem} ГБ RAM и нет swap — создаю /swapfile на 2 ГБ"
  fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
}

otp_major() {
  command -v erl >/dev/null 2>&1 || return 1
  erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().' 2>/dev/null
}

erlang_from_esl() {
  local codename
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"

  log "Пробую Erlang/OTP 27 из репозитория Erlang Solutions"

  # Хвосты прошлого прогона убираем сразу: недописанный source-лист сломал бы
  # любой последующий apt-get update.
  # --batch --yes обязательны: без них gpg спрашивает, перезаписывать ли
  # существующий файл, и скрипт встаёт на вопросе.
  rm -f /usr/share/keyrings/erlang-solutions.gpg /etc/apt/sources.list.d/erlang-solutions.list
  curl -fsSL --max-time 30 https://binaries2.erlang-solutions.com/GPG-KEY-pmanager.asc \
    | gpg --batch --yes --dearmor -o /usr/share/keyrings/erlang-solutions.gpg 2>/dev/null \
    || { warn "Ключ Erlang Solutions не скачался — перехожу к следующему способу"; return 1; }

  echo "deb [signed-by=/usr/share/keyrings/erlang-solutions.gpg] https://binaries2.erlang-solutions.com/ubuntu/ ${codename}-esl-erlang-27 contrib" \
    > /etc/apt/sources.list.d/erlang-solutions.list

  if apt-get update -qq 2>/dev/null && apt-get install -y -qq esl-erlang; then
    return 0
  fi

  warn "Репозиторий Erlang Solutions не отдал esl-erlang для ${codename}"
  rm -f /etc/apt/sources.list.d/erlang-solutions.list
  apt-get update -qq
  return 1
}

erlang_from_source() {
  log "Собираю Erlang/OTP $ERLANG_VERSION из исходников — это 15–25 минут"
  log "(быстрых путей не осталось: в репозитории этой Ubuntu OTP слишком старый)"

  # Старый OTP из apt только мешает: он останется в /usr/bin и будет путать.
  apt-get purge -y -qq 'erlang-*' >/dev/null 2>&1 || true
  apt-get install -y -qq autoconf m4 libncurses-dev libssl-dev

  local src="/usr/local/src/otp_src_${ERLANG_VERSION}"
  rm -rf "$src" "/usr/local/src/otp.tar.gz"
  mkdir -p /usr/local/src

  curl -fsSL --retry 3 -o /usr/local/src/otp.tar.gz \
    "https://github.com/erlang/otp/releases/download/OTP-${ERLANG_VERSION}/otp_src_${ERLANG_VERSION}.tar.gz" \
    || die "Не скачались исходники OTP ${ERLANG_VERSION}"

  tar -C /usr/local/src -xzf /usr/local/src/otp.tar.gz
  (
    cd "$src"
    # Ни JVM, ни GUI-приложений на сервере нет и не надо — экономим минуты сборки.
    ./configure --without-javac --without-wx --without-debugger \
                --without-observer --without-et --enable-kernel-poll >/dev/null
    make -j"$(build_jobs)" >/dev/null
    make install >/dev/null
  ) || die "Сборка OTP не удалась. Чаще всего это нехватка памяти — добавьте swap."

  rm -rf "$src" /usr/local/src/otp.tar.gz
  hash -r
}

install_erlang() {
  local have
  have="$(otp_major || echo 0)"

  if [[ "${have:-0}" -ge "$MIN_OTP" ]]; then
    log "Erlang/OTP $have уже установлен"
    return
  fi

  [[ "${have:-0}" != "0" ]] && \
    warn "Установлен OTP $have — для Elixir нужен минимум OTP $MIN_OTP, буду обновлять"

  erlang_from_esl || true

  have="$(otp_major || echo 0)"
  [[ "${have:-0}" -ge "$MIN_OTP" ]] && return

  # Пакеты Ubuntu пробуем только там, где они достаточно свежие (24.04 и новее).
  if [[ "${have:-0}" == "0" ]]; then
    apt-get install -y -qq erlang-nox erlang-dev >/dev/null 2>&1 || true
    have="$(otp_major || echo 0)"
    [[ "${have:-0}" -ge "$MIN_OTP" ]] && return
  fi

  erlang_from_source
}

ensure_swap
install_erlang

OTP_MAJOR="$(otp_major)"
[[ "$OTP_MAJOR" -ge "$MIN_OTP" ]] \
  || die "После установки получился OTP $OTP_MAJOR, а нужен минимум $MIN_OTP. Сборок Elixir под OTP $OTP_MAJOR не существует."
log "Erlang/OTP $OTP_MAJOR"

# --------------------------------------------------------------------------
# 3. Elixir (готовая сборка под установленный OTP)
# --------------------------------------------------------------------------

if command -v elixir >/dev/null 2>&1 && elixir -v 2>/dev/null | grep -q "Elixir $ELIXIR_VERSION"; then
  log "Elixir $ELIXIR_VERSION уже установлен"
else
  log "Ставлю Elixir $ELIXIR_VERSION (сборка под OTP $OTP_MAJOR)"
  ZIP_URL="https://github.com/elixir-lang/elixir/releases/download/v${ELIXIR_VERSION}/elixir-otp-${OTP_MAJOR}.zip"
  rm -rf /opt/elixir /tmp/elixir.zip
  curl -fsSL --retry 3 -o /tmp/elixir.zip "$ZIP_URL" \
    || die "Не скачался $ZIP_URL — проверьте, что для Elixir $ELIXIR_VERSION есть сборка под OTP $OTP_MAJOR"
  mkdir -p /opt/elixir
  unzip -q /tmp/elixir.zip -d /opt/elixir
  rm -f /tmp/elixir.zip
  for b in elixir elixirc mix iex; do
    ln -sf "/opt/elixir/bin/$b" "/usr/local/bin/$b"
  done
  echo 'export PATH="/opt/elixir/bin:$PATH"' > /etc/profile.d/elixir.sh
fi

elixir -v | tail -1

# --------------------------------------------------------------------------
# 4. Пользователь и каталоги
# --------------------------------------------------------------------------

if ! id -u "$APP_USER" >/dev/null 2>&1; then
  log "Создаю пользователя $APP_USER"
  useradd --system --create-home --home-dir "$BASE_DIR" --shell /bin/bash "$APP_USER"
fi

# `client_updates` — каталог сборок клиента: панель кладёт туда
# инсталляторы и `latest.yml`, приложение раздаёт его по `/client-updates`.
# Владелец — служебный пользователь: пишет в него нода, а не root.
mkdir -p "$SRC_DIR" "$REL_DIR" "$UPDATES_DIR"
chown -R "$APP_USER:$APP_USER" "$BASE_DIR"

# --------------------------------------------------------------------------
# 5. MySQL: база, пользователь, пароль
# --------------------------------------------------------------------------

systemctl enable --now mysql

if [[ -f "$ENV_FILE" ]] && grep -q '^DATABASE_URL=' "$ENV_FILE"; then
  log "Переиспользую существующие секреты из $ENV_FILE"
  # shellcheck disable=SC1090
  DB_PASS="$(sed -n 's|^DATABASE_URL=ecto://[^:]*:\([^@]*\)@.*|\1|p' "$ENV_FILE")"
  SECRET_KEY_BASE="$(sed -n 's/^SECRET_KEY_BASE=//p' "$ENV_FILE")"
  # Файл переписывается целиком, поэтому всё дописанное руками надо
  # прочитать до этого. Origin'ы панели — как раз такое поле: пароли
  # скрипт генерирует сам, а адрес панели знает только администратор.
  ADMIN_ORIGINS="${ADMIN_ORIGINS:-$(sed -n 's/^ADMIN_ORIGINS=//p' "$ENV_FILE")}"
  CLIENT_FEED_URL="${CLIENT_FEED_URL:-$(sed -n 's/^CLIENT_FEED_URL=//p' "$ENV_FILE")}"
else
  DB_PASS="$(openssl rand -hex 24)"
  SECRET_KEY_BASE="$(openssl rand -base64 64 | tr -d '\n')"
fi

log "Настраиваю MySQL"
mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

# --------------------------------------------------------------------------
# 6. Файл окружения
# --------------------------------------------------------------------------

# Схема нужна раньше, чем выпускается сертификат: адрес фида пишется
# в env-файл, а `SCHEME` вычисляется только в блоке TLS ниже.
if [[ "${SKIP_TLS:-0}" == "1" ]]; then
  UPDATES_SCHEME="http"
else
  UPDATES_SCHEME="https"
fi

log "Пишу $ENV_FILE"
cat > "$ENV_FILE" <<ENV
PHX_SERVER=true
PORT=4000
PHX_HOST=${DOMAIN}
SECRET_KEY_BASE=${SECRET_KEY_BASE}
DATABASE_URL=ecto://${DB_USER}:${DB_PASS}@127.0.0.1/${DB_NAME}
POOL_SIZE=10
# Origin'ы панели администратора через запятую, например
# https://admin.example.com. Пусто — панель снаружи не пускается: CORS для
# `/admin/*` разрешает только перечисленные адреса, `*` не поддерживается.
ADMIN_ORIGINS=${ADMIN_ORIGINS:-}
# Автообновление клиента. Каталог раздаётся самим приложением по
# `/client-updates`, панель кладёт туда инсталляторы и `latest.yml`.
#
# Слеш в конце адреса обязателен: `electron-updater` строит ссылку на
# `latest.yml` как `new URL(file, feed_url)`, а без слеша такое
# разрешение отбрасывает последний сегмент пути и уводит клиента за
# фидом в корень домена. Сервер адрес всё равно нормализует, но
# держать в файле заведомо рабочее значение дешевле, чем однажды
# разбираться, почему обновление молчит.
CLIENT_UPDATES_DIR=${UPDATES_DIR}
CLIENT_FEED_URL=${CLIENT_FEED_URL:-${UPDATES_SCHEME}://${DOMAIN}/client-updates/}
MIX_ENV=prod
LANG=C.UTF-8
ENV
chmod 600 "$ENV_FILE"
chown root:root "$ENV_FILE"

# --------------------------------------------------------------------------
# 7. Исходники
# --------------------------------------------------------------------------

if [[ -n "${REPO_URL:-}" ]]; then
  if [[ -d "$SRC_DIR/.git" ]]; then
    log "Обновляю исходники из $REPO_URL"
    sudo -u "$APP_USER" git -C "$SRC_DIR" fetch --all --prune
    sudo -u "$APP_USER" git -C "$SRC_DIR" checkout "$REPO_REF"
    sudo -u "$APP_USER" git -C "$SRC_DIR" reset --hard "origin/$REPO_REF"
  else
    log "Клонирую $REPO_URL"
    rm -rf "$SRC_DIR"
    sudo -u "$APP_USER" git clone --branch "$REPO_REF" "$REPO_URL" "$SRC_DIR"
  fi
elif [[ "$(readlink -f "$LOCAL_SRC")" == "$(readlink -f "$SRC_DIR")" ]]; then
  log "Скрипт запущен из $SRC_DIR — исходники уже на месте"
  chown -R "$APP_USER:$APP_USER" "$SRC_DIR"
else
  log "Копирую исходники из $LOCAL_SRC"
  mkdir -p "$SRC_DIR"
  # _build и deps не переносим: NIF собираются здесь, под этой машиной.
  tar -C "$LOCAL_SRC" \
      --exclude=.git --exclude=_build --exclude=deps --exclude=priv/plts \
      -cf - . | tar -C "$SRC_DIR" -xf -
  chown -R "$APP_USER:$APP_USER" "$SRC_DIR"
fi

# --------------------------------------------------------------------------
# 8. Сборка релиза
# --------------------------------------------------------------------------

log "Собираю релиз (первый раз это несколько минут: argon2_elixir — NIF на C)"
systemctl stop "$SERVICE" 2>/dev/null || true

# force_ssl попадает в релиз на этапе компиляции, а Elixir отслеживает
# изменения конфига по файлам, а не по переменным окружения. Поэтому смену
# режима фиксируем маркером и пересобираем приложение начисто.
MARKER="$SRC_DIR/.deploy-plain-http"
if [[ "$(cat "$MARKER" 2>/dev/null || echo 0)" != "$PLAIN_HTTP" ]]; then
  rm -rf "$SRC_DIR/_build/prod/lib/block_poker"
  echo "$PLAIN_HTTP" > "$MARKER"
  chown "$APP_USER:$APP_USER" "$MARKER"
fi

sudo -u "$APP_USER" env \
  MIX_ENV=prod \
  HOME="$BASE_DIR" \
  BLOCK_POKER_ALLOW_PLAIN_HTTP="$PLAIN_HTTP" \
  PATH="/opt/elixir/bin:/usr/local/bin:/usr/bin:/bin" \
  bash -c "
    set -e
    cd '$SRC_DIR'
    mix local.hex --force --if-missing
    mix local.rebar --force --if-missing
    mix deps.get --only prod
    mix deps.compile
    mix compile
    mix release --overwrite --path '$REL_DIR'
  "

# --------------------------------------------------------------------------
# 9. Миграции и сид
# --------------------------------------------------------------------------

# Через `mix`, а не `bin/block_poker eval`: релиз собирается тут же из
# исходников, поэтому Elixir и `_build/prod` на машине есть, а `eval` на
# этой конфигурации падает при завершении ноды, съедая настоящую ошибку
# (подробности — в шапке `deploy/update.sh`).
#
# PHX_SERVER не передаётся намеренно: поднимать эндпоинт посреди деплоя
# незачем.
run_mix() {
  sudo -u "$APP_USER" env \
    MIX_ENV=prod \
    HOME="$BASE_DIR" \
    LANG=C.UTF-8 \
    PATH="/opt/elixir/bin:/usr/local/bin:/usr/bin:/bin" \
    DATABASE_URL="ecto://${DB_USER}:${DB_PASS}@127.0.0.1/${DB_NAME}" \
    SECRET_KEY_BASE="$SECRET_KEY_BASE" \
    PHX_HOST="$DOMAIN" \
    POOL_SIZE=2 \
    bash -c "cd '$SRC_DIR' && mix $1"
}

log "Накатываю миграции"
run_mix "ecto.migrate"

log "Засеваю сетку лимитов кэш-игры (идемпотентно)"
run_mix "cash_game.seed"

log "Засеваю сетку гипер-турниров Sit & Go (идемпотентно)"
run_mix "sit_n_go.seed"

# Шаблоны MTT. Инстансы из них делает не сид, а `TournamentScheduler`
# внутри ноды: он тикает раз в минуту и разворачивает расписание в
# запуски. Сид кладёт только сами шаблоны с уровнями, выплатами и
# расписанием — без них планировщику не из чего создавать турниры.
log "Засеваю сетку многостоловых турниров (идемпотентно)"
run_mix "tournament.seed"

# --------------------------------------------------------------------------
# 10. systemd
# --------------------------------------------------------------------------

log "Ставлю systemd-юнит"
cat > "/etc/systemd/system/${SERVICE}.service" <<UNIT
[Unit]
Description=Block Poker backend
After=network-online.target mysql.service
Wants=network-online.target
Requires=mysql.service

[Service]
Type=exec
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${BASE_DIR}
EnvironmentFile=${ENV_FILE}
Environment=HOME=${BASE_DIR}
ExecStart=${REL_DIR}/bin/block_poker start
ExecStop=${REL_DIR}/bin/block_poker stop
Restart=on-failure
RestartSec=5
# Столы держат тысячи WebSocket-соединений.
LimitNOFILE=65536
# Рестарт аннулирует незавершённые раздачи (см. §8 CLAUDE.md) —
# даём процессам столов время корректно погаснуть.
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable "$SERVICE"
systemctl restart "$SERVICE"

# --------------------------------------------------------------------------
# 11. nginx
# --------------------------------------------------------------------------

log "Настраиваю nginx для $DOMAIN"
rm -f /etc/nginx/sites-enabled/default

# На голом IP имени нет — ловим любой Host.
if [[ "$PLAIN_HTTP" == "1" ]]; then
  SERVER_NAME="_"
else
  SERVER_NAME="$DOMAIN"
fi

cat > "/etc/nginx/sites-available/${SERVICE}" <<'NGINX_HEAD'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

NGINX_HEAD

cat >> "/etc/nginx/sites-available/${SERVICE}" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_NAME};

    # Клиент — Electron, статики нет. Загружать нечего, но auth-запросы
    # не должны упираться в дефолтный лимит.
    client_max_body_size 1m;

    # Основной канал связи. Без Upgrade-заголовков и длинных таймаутов
    # nginx рвал бы игровые сокеты каждые 60 секунд, и игроки уходили бы
    # в grace-период и авто-фолд.
    location /socket/ {
        proxy_pass http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }

    # Загрузка сборки клиента — единственная ручка с большим телом.
    # Общий `client_max_body_size 1m` отвергал бы инсталлятор на сотне
    # мегабайт, причём ответом `413` без CORS-заголовков: в браузере это
    # выглядит как ошибка CORS, а не как «файл слишком большой».
    #
    # Предел ставит приложение (`Api.Plugs.ClientReleaseUpload`), а не
    # прокси: держать его в двух местах значит однажды развести их.
    location /admin/client-releases {
        proxy_pass http://127.0.0.1:4000;
        proxy_http_version 1.1;
        client_max_body_size 0;
        # Не копим гигабайт на диске прокси: тело едет в приложение потоком.
        proxy_request_buffering off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    # Сокет панели администратора. Отдельный блок, а не общий с игровым:
    # пути разные, и `location /socket/` его не покрывает — без этого
    # `/admin/socket/websocket` уходит в `location /`, где Upgrade-заголовков
    # нет, и god-mode не подключается вовсе при живом игровом сокете.
    location /admin/socket/ {
        proxy_pass http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }

    location / {
        proxy_pass http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        # Без этого заголовка force_ssl из config/prod.exs уходит в петлю редиректов.
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX

ln -sf "/etc/nginx/sites-available/${SERVICE}" "/etc/nginx/sites-enabled/${SERVICE}"
nginx -t
systemctl reload nginx

# --------------------------------------------------------------------------
# 12. Файрвол и TLS
# --------------------------------------------------------------------------

log "Открываю порты"
ufw allow OpenSSH >/dev/null
ufw allow 'Nginx Full' >/dev/null
ufw --force enable >/dev/null

if [[ "${SKIP_TLS:-0}" == "1" ]]; then
  warn "TLS не настраивается: сервер отвечает по обычному http:// на $DOMAIN"
  SCHEME="http"
  WS_SCHEME="ws"
else
  log "Выпускаю сертификат Let's Encrypt для $DOMAIN"
  apt-get install -y -qq certbot python3-certbot-nginx

  if [[ -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
    log "Сертификат для $DOMAIN уже есть — пропускаю выпуск"
  else
    CERTBOT_MAIL=(--register-unsafely-without-email)
    [[ -n "${EMAIL:-}" ]] && CERTBOT_MAIL=(-m "$EMAIL")

    certbot --nginx -d "$DOMAIN" "${CERTBOT_MAIL[@]}" \
      --agree-tos --non-interactive --redirect \
      || die "certbot не справился. Проверьте, что порт 80 открыт снаружи и $DOMAIN резолвится в этот сервер."
  fi
  systemctl reload nginx
  SCHEME="https"
  WS_SCHEME="wss"
fi

# --------------------------------------------------------------------------
# Готово
# --------------------------------------------------------------------------

sleep 2
systemctl is-active --quiet "$SERVICE" || die "Сервис не поднялся: journalctl -u $SERVICE -n 50"

cat <<DONE

$(log "Готово")

  WebSocket:   ${WS_SCHEME}://${DOMAIN}/socket/websocket?token=...
  HTTP API:    ${SCHEME}://${DOMAIN}/api/auth/login
  Healthcheck: ${SCHEME}://${DOMAIN}/health

  Логи:        journalctl -u ${SERVICE} -f
  Рестарт:     systemctl restart ${SERVICE}
  Консоль:     sudo -u ${APP_USER} ${REL_DIR}/bin/block_poker remote
  Секреты:     ${ENV_FILE}

  Обновление — этот же скрипт ещё раз:
      cd ${SRC_DIR} && DOMAIN=${DOMAIN} EMAIL=\${EMAIL} bash deploy/ubuntu.sh

DONE
