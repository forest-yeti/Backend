#!/usr/bin/env bash
#
# Block Poker — обновление уже развёрнутой ноды.
#
# Отличие от `ubuntu.sh` не в том, что здесь «меньше шагов», а в том, что
# здесь нет ни одного шага, меняющего окружение. Erlang, Elixir, MySQL,
# systemd, nginx, файрвол и сертификат не трогаются вовсе: обновление —
# это новый код поверх той же машины, и всё, что к коду не относится,
# трогать незачем. Отсюда и время: минуты вместо десятков минут.
#
# Порядок выбран так, чтобы простой был как можно короче. Компиляция —
# самая долгая часть — идёт **на живом сервисе**: она пишет в `_build`,
# которого работающий релиз не касается. Останавливаемся только на сборку
# самого релиза, миграции и старт.
#
# Запуск — одна команда, ничего предварительно тянуть не надо:
#
#     sudo bash deploy/update.sh                 # pull + сборка + миграции + сид
#     sudo bash deploy/update.sh --no-pull       # взять код как есть, без git
#     sudo bash deploy/update.sh --no-seed       # без сида
#     sudo bash deploy/update.sh --retier        # плюс перезалив таблиц призов
#     sudo bash deploy/update.sh --regrid        # перезалить сетку MTT целиком
#
# `git pull` делает сам скрипт и делает его **от имени владельца каталога**.
# Вручную это неудобно: `/opt/block_poker/src` принадлежит служебному
# пользователю, и pull под собой упрётся в права, а под root — оставит
# root-овые файлы, на которых потом споткнётся сборка.
#
# Переменные окружения:
#   APP_USER    системный пользователь (по умолчанию blockpoker)
#   BASE_DIR    корень установки (по умолчанию /opt/block_poker)
#   REPO_REF    ветка (по умолчанию текущая)

set -Eeuo pipefail

APP_USER="${APP_USER:-blockpoker}"
BASE_DIR="${BASE_DIR:-/opt/block_poker}"
SRC_DIR="$BASE_DIR/src"
REL_DIR="$BASE_DIR/current"
ENV_FILE="/etc/block_poker.env"
SERVICE="block-poker"

DO_SEED=1
DO_RETIER=0
DO_REGRID=0
# Тянуть по умолчанию: обновление почти всегда означает «взять свежий код»,
# и отдельный флаг под это лишь добавлял бы шаг, который забывают.
DO_PULL=1

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

trap 'die "Прервано на строке $LINENO. Сервис мог остаться остановленным: systemctl status '"$SERVICE"'"' ERR

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-seed) DO_SEED=0 ;;
    --retier)  DO_RETIER=1 ;;
    --regrid)  DO_REGRID=1 ;;
    --no-pull) DO_PULL=0 ;;
    # Оставлен ради совместимости: раньше pull был по флагу, теперь он
    # поведение по умолчанию.
    --pull)    DO_PULL=1 ;;
    -h|--help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         die "неизвестный аргумент: $1" ;;
  esac
  shift
done

[[ "$(id -u)" -eq 0 ]] || die "нужен root: sudo bash deploy/update.sh"

# --------------------------------------------------------------------------
# 1. Это точно обновление, а не первая установка
# --------------------------------------------------------------------------
#
# Проверяется явно, потому что update.sh молча не создаст ни базы, ни
# сервиса: попытка «обновить» пустую машину дала бы набор невнятных ошибок
# вместо одной внятной.

[[ -f "$ENV_FILE" ]] || die "нет $ENV_FILE — сначала разверните ноду: bash deploy/ubuntu.sh"
[[ -d "$SRC_DIR" ]]  || die "нет $SRC_DIR — сначала разверните ноду: bash deploy/ubuntu.sh"
systemctl list-unit-files "${SERVICE}.service" --no-legend | grep -q . \
  || die "нет юнита ${SERVICE} — сначала разверните ноду: bash deploy/ubuntu.sh"

# --------------------------------------------------------------------------
# 2. Исходники
# --------------------------------------------------------------------------

LOCAL_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Каталог мог остаться с чужим владельцем — например, после ручного
# `sudo git pull`. Приводим права до всего остального: и git, и сборка
# должны идти от одного пользователя, иначе первая же из них упрётся
# в чужие файлы.
if [[ -d "$SRC_DIR" ]]; then
  chown -R "$APP_USER:$APP_USER" "$SRC_DIR"
fi

if [[ "$DO_PULL" -eq 1 && -d "$SRC_DIR/.git" ]]; then
  REF="${REPO_REF:-$(sudo -u "$APP_USER" git -C "$SRC_DIR" rev-parse --abbrev-ref HEAD)}"
  log "Тяну $REF"

  # `reset --hard`, а не `pull`: локальные правки на боевой ноде — это не
  # работа, которую надо беречь, а расхождение с репозиторием, из-за
  # которого merge встанет посреди деплоя и попросит разрешить конфликт.
  sudo -u "$APP_USER" git -C "$SRC_DIR" fetch --all --prune
  sudo -u "$APP_USER" git -C "$SRC_DIR" reset --hard "origin/$REF"

elif [[ "$(readlink -f "$LOCAL_SRC")" != "$(readlink -f "$SRC_DIR")" ]]; then
  # Скрипт запущен из скопированного каталога — переносим код на место.
  log "Копирую исходники из $LOCAL_SRC"
  # `_build` и `deps` остаются на месте — в них весь смысл быстрого
  # обновления: зависимости и NIF уже собраны под эту машину.
  tar -C "$LOCAL_SRC" \
      --exclude=.git --exclude=_build --exclude=deps --exclude=priv/plts \
      -cf - . | tar -C "$SRC_DIR" -xf -
  chown -R "$APP_USER:$APP_USER" "$SRC_DIR"

elif [[ "$DO_PULL" -eq 1 ]]; then
  warn "$SRC_DIR не git-репозиторий — тянуть неоткуда, собираю то, что лежит"

else
  log "Беру код как есть из $SRC_DIR"
fi

if [[ -d "$SRC_DIR/.git" ]]; then
  log "Разворачивается: $(sudo -u "$APP_USER" git -C "$SRC_DIR" log -1 --format='%h %s')"
fi

# --------------------------------------------------------------------------
# 3. Компиляция на живом сервисе
# --------------------------------------------------------------------------
#
# Самый долгий шаг, и он не требует простоя: `mix compile` пишет в
# `_build`, а работающий релиз живёт в `current` и туда не заглядывает.
# Если компиляция упадёт — сервис так и останется работать на старом коде,
# а это ровно то поведение, которое нужно от неудачного обновления.

log "Компилирую (сервис продолжает работать)"
sudo -u "$APP_USER" env \
  MIX_ENV=prod \
  HOME="$BASE_DIR" \
  PATH="/opt/elixir/bin:/usr/local/bin:/usr/bin:/bin" \
  bash -c "
    set -e
    cd '$SRC_DIR'
    mix local.hex --force --if-missing
    mix local.rebar --force --if-missing
    mix deps.get --only prod
    mix deps.compile
    mix compile
  "

# --------------------------------------------------------------------------
# 4. Сборка релиза, миграции, старт
# --------------------------------------------------------------------------
#
# Отсюда начинается простой. Сервис останавливается, потому что
# `mix release --overwrite` переписывает файлы, которые работающая нода
# держит открытыми.
#
# По §8 CLAUDE.md рестарт гасит все `TableServer`: незавершённые раздачи
# аннулируются, ставки возвращаются из снапшота стеков. Обновляйтесь
# в окно низкой активности.

DOWNTIME_START="$(date +%s)"

log "Останавливаю $SERVICE"
systemctl stop "$SERVICE"

log "Собираю релиз"
sudo -u "$APP_USER" env \
  MIX_ENV=prod \
  HOME="$BASE_DIR" \
  PATH="/opt/elixir/bin:/usr/local/bin:/usr/bin:/bin" \
  bash -c "cd '$SRC_DIR' && mix release --overwrite --path '$REL_DIR'"

# Секреты читаются из того же файла, что видит systemd, — второй копии
# паролей на машине не заводится.
DB_URL="$(sed -n 's/^DATABASE_URL=//p' "$ENV_FILE")"
SECRET_KEY_BASE="$(sed -n 's/^SECRET_KEY_BASE=//p' "$ENV_FILE")"
PHX_HOST="$(sed -n 's/^PHX_HOST=//p' "$ENV_FILE")"

[[ -n "$DB_URL" ]] || die "в $ENV_FILE нет DATABASE_URL"

# Миграции и сид идут через `mix`, а не через `bin/block_poker eval`.
#
# `eval` — штатный путь для «тонкого» релиза, приехавшего на машину без
# исходников. Здесь не тот случай: релиз собирается тут же из исходников,
# значит Elixir и `_build/prod` никуда не делись, и звать их напрямую
# не хуже.
#
# А главное — `eval` на этой конфигурации падает при завершении ноды:
# `Kernel pid terminated (logger)` с уже мёртвым `code_server`. Падает и
# тогда, когда делать нечего и миграций нет. Настоящая ошибка при этом
# не печатается: нода уже гасла, и логгер умирал, пытаясь о ней сообщить.
# Держать в деплое путь, который молча съедает диагностику, нельзя.
#
# PHX_SERVER не передаётся намеренно: `mix ecto.migrate` эндпоинт не
# поднимает, и открывать порт посреди деплоя ему незачем.
run_mix() {
  sudo -u "$APP_USER" env \
    MIX_ENV=prod \
    HOME="$BASE_DIR" \
    LANG=C.UTF-8 \
    PATH="/opt/elixir/bin:/usr/local/bin:/usr/bin:/bin" \
    DATABASE_URL="$DB_URL" \
    SECRET_KEY_BASE="$SECRET_KEY_BASE" \
    PHX_HOST="$PHX_HOST" \
    POOL_SIZE=2 \
    bash -c "cd '$SRC_DIR' && mix $1"
}

log "Накатываю миграции"
run_mix "ecto.migrate"

if [[ "$DO_SEED" -eq 1 ]]; then
  log "Сею сетки (идемпотентно: существующие шаблоны не трогаются)"
  run_mix "cash_game.seed"
  run_mix "sit_n_go.seed"
  # Шаблоны MTT. Инстансы из них делает `TournamentScheduler` внутри
  # ноды, а не сид: он тикает раз в минуту и разворачивает расписание
  # в запуски.
  run_mix "tournament.seed"
fi

# Полная замена турнирной сетки. Обычный сид существующие шаблоны
# пропускает — а правка структуры уровней, цен или расписания меняет
# именно их. Отдельным флагом, потому что вместе с шаблонами уезжают
# и их инстансы: анонсированные турниры исчезнут из витрины, поэтому
# делать это стоит в окно, когда в них никто не записан.
if [[ "$DO_REGRID" -eq 1 ]]; then
  log "Перезаливаю сетку MTT (старые шаблоны и их инстансы удаляются)"
  run_mix "tournament.seed --reset --force"
fi

if [[ "$DO_RETIER" -eq 1 ]]; then
  log "Перезаливаю таблицы призов Sit & Go"
  run_mix "sit_n_go.seed --retier"
fi

log "Запускаю $SERVICE"
systemctl start "$SERVICE"

DOWNTIME=$(( $(date +%s) - DOWNTIME_START ))

# --------------------------------------------------------------------------
# 5. Проверка
# --------------------------------------------------------------------------
#
# Без неё скрипт сообщал бы об успехе всякий раз, когда сумел запустить
# systemd, — а «запустился» и «работает» это разные события.

log "Проверяю"

for _ in $(seq 1 20); do
  if systemctl is-active --quiet "$SERVICE"; then break; fi
  sleep 1
done

systemctl is-active --quiet "$SERVICE" \
  || die "сервис не поднялся: journalctl -u $SERVICE -n 100"

PORT="$(sed -n 's/^PORT=//p' "$ENV_FILE")"
PORT="${PORT:-4000}"

HEALTH=""
for _ in $(seq 1 20); do
  HEALTH="$(curl -fsS "http://127.0.0.1:${PORT}/health" 2>/dev/null || true)"
  [[ -n "$HEALTH" ]] && break
  sleep 1
done

if [[ -z "$HEALTH" ]]; then
  warn "сервис активен, но /health не отвечает — смотрите journalctl -u $SERVICE -n 100"
else
  log "Готово. Простой: ${DOWNTIME} с. /health отвечает."
fi

printf '\n  журнал:  journalctl -u %s -f\n' "$SERVICE"
printf '  консоль: sudo -u %s HOME=%s %s/bin/block_poker remote\n\n' \
  "$APP_USER" "$BASE_DIR" "$REL_DIR"
