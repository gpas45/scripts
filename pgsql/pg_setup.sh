#!/usr/bin/env bash
set -euo pipefail

# -------- Параметры (можно переопределить аргументами/переменными окружения) --------
PGVER="${PGVER:-1c-18}"                       # пример: 1c-18
TIMEZONE="${TIMEZONE:-Asia/Yekaterinburg}"
DEFAULT_LANG="${DEFAULT_LANG:-ru_RU.UTF-8}"   # ru_RU.UTF-8 по умолчанию
LOCALES=("ru_RU.UTF-8" "en_US.UTF-8")
BASHRC_URL="${BASHRC_URL:-https://raw.githubusercontent.com/RomNero/YouTube-Infos/main/Linux-System-Configs/.bashrc}"
POSTGRES_PASS="${POSTGRES_PASS:-}"             # можно передать заранее, иначе сгенерируется

# Логирование: файл и уровень вывода (INFO|WARN|ERR)
LOG_FILE="${LOG_FILE:-/var/log/pgpro-setup.log}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"

# -------- Аргументы --------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pgver) PGVER="$2"; shift 2;;
    --timezone) TIMEZONE="$2"; shift 2;;
    --lang|--default-lang) DEFAULT_LANG="$2"; shift 2;;
    --postgres-pass) POSTGRES_PASS="$2"; shift 2;;
    -h|--help)
      echo "Usage: sudo $0 [--pgver 1c-18] [--timezone Asia/Yekaterinburg] [--default-lang ru_RU.UTF-8] [--postgres-pass PASS] [env: LOG_LEVEL=INFO/WARN/ERR LOG_FILE=/path/to/log]"
      exit 0;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

# -------- Проверки/переменные путей --------
if [[ $EUID -ne 0 ]]; then echo "Запустите от root (sudo)."; exit 1; fi
. /etc/os-release
if ! echo "${ID_LIKE:-$ID}" | tr '[:upper:]' '[:lower:]' | grep -Eq 'debian|ubuntu'; then
  echo "Скрипт поддерживает Debian/Ubuntu."; exit 1
fi

PG_SERVICE="postgrespro-${PGVER}"
PG_BASE="/opt/pgpro/${PGVER}"
PG_BIN="${PG_BASE}/bin"
PG_DATA="/var/lib/pgpro/${PGVER}/data"
PG_HBA="${PG_DATA}/pg_hba.conf"
PG_CONF="${PG_DATA}/postgresql.conf"
PG_MAJOR="$(echo "${PGVER}" | sed -E 's/.*-([0-9]+).*/\1/')"

export DEBIAN_FRONTEND=noninteractive

# -------- Логгер --------
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 640 "$LOG_FILE" || true

lvl_num() { case "$1" in ERR) echo 0;; WARN) echo 1;; INFO) echo 2;; *) echo 2;; esac; }
LOG_THRESHOLD="$(lvl_num "$LOG_LEVEL")"

log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date '+%F %T')"
  echo "[$ts] [$level] $msg" >> "$LOG_FILE"
  # В консоль — если уровень сообщения >= порога
  if [[ "$(lvl_num "$level")" -le "$LOG_THRESHOLD" ]]; then
    echo "[$level] $msg"
  fi
}
log_info() { log INFO "$*"; }
log_warn() { log WARN "$*"; }
log_err()  { log ERR  "$*"; }

trap 'log_err "Необработанная ошибка на строке $LINENO"; exit 1' ERR

# Универсальный раннер: вывод команды — только в лог, в консоль — шаги/статусы
run() {
  local desc="$1"; shift
  log_info "$desc"
  if "$@" >> "$LOG_FILE" 2>&1; then
    log_info "OK: $desc"
  else
    log_err "FAIL: $desc"
    return 1
  fi
}

# -------- Предварительные проверки: наличие установленного PG и каталога данных --------

# Функция вопроса (Y/N | Д/Н)
ask_yes_no() {
  local prompt="$1"
  local def="${2:-N}"   # по умолчанию: N
  local ans=""
  read -r -p "$prompt " ans || true
  ans="${ans:-$def}"
  case "$ans" in
    [Yy]|[Yy][Ee][Ss]|[Дд]|[Дд][Аа]) return 0 ;;
    *) return 1 ;;
  esac
}

# 1) Проверка установлен ли PostgreSQL/Postgres Pro (любой сервер)
log_info "Проверка установленной СУБД"
PG_INSTALLED=0
if dpkg -l 2>/dev/null | grep -Eq '^ii\s+postgrespro-.*-server\b'; then PG_INSTALLED=1; fi
if dpkg -l 2>/dev/null | grep -Eq '^ii\s+postgresql(-[0-9]+)?\b'; then PG_INSTALLED=1; fi
if systemctl list-unit-files 2>/dev/null | grep -qE '^postgrespro-.*\.service'; then PG_INSTALLED=1; fi
if [[ -x "${PG_BIN}/postgres" ]]; then PG_INSTALLED=1; fi

if [[ "${PG_INSTALLED}" -eq 1 ]]; then
  log_err "Обнаружена установленная PostgreSQL/Postgres Pro. Прерывание."
  exit 1
fi

# 2) Проверка существования каталога данных кластера
DID_DATA_BACKUP=0
if [[ -d "${PG_DATA}" ]]; then
  log_warn "Обнаружен каталог данных: ${PG_DATA}"
  if ask_yes_no "Продолжить установку? Это может перезаписать данные. [y/N]" "N"; then
    if ask_yes_no "Сделать резервную копию каталога (переименовать в ${PG_DATA}.backup)? [Y/n]" "Y"; then
      PG_DATA_BKP="${PG_DATA}.backup"
      if [[ -e "${PG_DATA_BKP}" ]]; then
        PG_DATA_BKP="${PG_DATA}.backup.$(date +%F_%H%M%S)"
      fi
      run "Резервная копия каталога данных в ${PG_DATA_BKP}" mv "${PG_DATA}" "${PG_DATA_BKP}"
      DID_DATA_BACKUP=1
    else
      log_warn "Резервная копия не выполнена. Старый ${PG_DATA} будет удалён при переинициализации."
    fi
  else
    log_info "Операция отменена пользователем."
    exit 0
  fi
fi

# -------- Обновление системы и базовые пакеты --------
run "Обновление индексов пакетов" apt-get update -y
run "Обновление системы (dist-upgrade)" apt-get -o Dpkg::Options::="--force-confnew" dist-upgrade -y
run "Установка базовых пакетов" apt-get install -y mc nano console-setup net-tools htop tmux curl ca-certificates gnupg lsb-release locales sudo

# -------- Локали --------
log_info "Настройка локалей"
for L in "${LOCALES[@]}"; do
  grep -qE "^${L}\s+UTF-8" /etc/locale.gen 2>/dev/null || echo "${L} UTF-8" >> /etc/locale.gen
done
run "Генерация локалей" locale-gen
run "Применение локали по умолчанию (${DEFAULT_LANG})" update-locale LANG="${DEFAULT_LANG}"

# Применить локаль немедленно в текущем сеансе
if [[ -f /etc/default/locale ]]; then
  # shellcheck disable=SC1091
  . /etc/default/locale || true
fi
export LANG="${DEFAULT_LANG}"
export LC_ALL="${DEFAULT_LANG}"

# -------- Часовой пояс --------
if command -v timedatectl >/dev/null 2>&1; then
  run "Установка часового пояса ${TIMEZONE}" timedatectl set-timezone "${TIMEZONE}"
else
  run "Установка часового пояса (legacy) ${TIMEZONE}" ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
  run "Применение tzdata" dpkg-reconfigure -f noninteractive tzdata
fi

# -------- Настройка консоли (console-setup) --------
log_info "Настройка клавиатуры и консоли"
bash -c '
  set -e
  sed -i "s/^XKBMODEL=.*/XKBMODEL=\"pc105\"/" /etc/default/keyboard || true
  grep -q "^XKBMODEL=" /etc/default/keyboard || echo "XKBMODEL=\"pc105\"" >> /etc/default/keyboard
  sed -i "s/^XKBLAYOUT=.*/XKBLAYOUT=\"ru,us\"/" /etc/default/keyboard || true
  grep -q "^XKBLAYOUT=" /etc/default/keyboard || echo "XKBLAYOUT=\"ru,us\"" >> /etc/default/keyboard
  sed -i "s/^XKBVARIANT=.*/XKBVARIANT=\",\"/" /etc/default/keyboard || true
  grep -q "^XKBVARIANT=" /etc/default/keyboard || echo "XKBVARIANT=\",\"" >> /etc/default/keyboard
  sed -i "s/^XKBOPTIONS=.*/XKBOPTIONS=\"grp:alt_shift_toggle\"/" /etc/default/keyboard || true
  grep -q "^XKBOPTIONS=" /etc/default/keyboard || echo "XKBOPTIONS=\"grp:alt_shift_toggle\"" >> /etc/default/keyboard
' >> "$LOG_FILE" 2>&1 || true

cat >/etc/default/console-setup <<'EOF'
ACTIVE_CONSOLES="/dev/tty[1-6]"
CHARMAP="UTF-8"
CODESET="guess"
FONTFACE="TerminusBold"
FONTSIZE="8x16"
EOF

run "Перезапуск keyboard-setup" service keyboard-setup restart
#run "Применение setupcon" bash -lc "setupcon -k"  # через оболочку, чтобы попасть в лог
setupcon -k >/dev/null 2>&1 || true

# -------- .bashrc для окружения bash --------
run "Загрузка .bashrc из репозитория" curl -fsSL "${BASHRC_URL}" -o /etc/skel/.bashrc
run "Установка .bashrc для root" install -m 0644 /etc/skel/.bashrc /root/.bashrc

# Применить .bashrc немедленно
# shellcheck disable=SC1090
source /root/.bashrc || true

# Если пользователь postgres уже есть — положим .bashrc ему тоже
if id postgres >/dev/null 2>&1; then
  POSTGRES_HOME="$(getent passwd postgres | cut -d: -f6)"
  run "Установка .bashrc для postgres" install -o postgres -g postgres -m 0644 /etc/skel/.bashrc "${POSTGRES_HOME}/.bashrc"
fi

# -------- Репозиторий Postgres Pro 1C (версия параметризуется) --------
REPO_SCRIPT_URL="https://repo.postgrespro.ru/${PGVER}/keys/pgpro-repo-add.sh"
run "Загрузка скрипта репозитория Postgres Pro (${PGVER})" curl -fsSL "${REPO_SCRIPT_URL}" -o /tmp/pgpro-repo-add.sh
run "Добавление репозитория Postgres Pro" bash /tmp/pgpro-repo-add.sh
run "Обновление индексов пакетов (после добавления репо)" apt-get update -y

# -------- Установка Postgres Pro 1C --------
run "Установка пакетов postgrespro-${PGVER}" apt-get install -y "postgrespro-${PGVER}"

# -------- Заморозка пакетов (hold) --------
log_info "Заморозка пакетов Postgres Pro и общих зависимостей"
run "Hold postgresql-common/clients" bash -lc "apt-mark hold postgresql-common postgresql-client-common || true"
run "Hold libpq5" bash -lc "apt-mark hold libpq5 || true"
run "Hold postgrespro-${PGVER}*" bash -lc "apt-mark hold \"postgrespro-${PGVER}\" \"postgrespro-${PGVER}-client\" \"postgrespro-${PGVER}-contrib\" \"postgrespro-${PGVER}-libs\" \"postgrespro-${PGVER}-server\" || true"

# -------- Символические ссылки через pg-wrapper --------
run "Обновление ссылок через pg-wrapper" "${PG_BIN}/pg-wrapper" links update

# -------- Старт/стоп для проверки, затем очистка каталога --------
run "Пробный старт сервиса ${PG_SERVICE}" systemctl start "${PG_SERVICE}"
if systemctl is-active --quiet "${PG_SERVICE}"; then
  run "Остановка сервиса ${PG_SERVICE}" systemctl stop "${PG_SERVICE}"
fi

run "Очистка каталога данных перед initdb" bash -lc "rm -rf \"${PG_DATA}\""

# -------- Инициализация кластера для 1С с нужной локалью --------
run "Инициализация кластера (--tune=1c, locale=${DEFAULT_LANG})" "${PG_BIN}/pg-setup" initdb --tune=1c --locale="${DEFAULT_LANG}"

# -------- (Опционально) настройки для 1С: UNIX-сокет --------
# (при необходимости — добавить правки конфигов и reload)

# -------- Включение контрольных сумм, если версия < 18 --------
if [[ "${PG_MAJOR}" =~ ^[0-9]+$ ]] && [[ "${PG_MAJOR}" -lt 18 ]]; then
  run "Включение контрольных сумм страницы (pg_checksums)" "${PG_BIN}/pg_checksums" --enable -D "${PG_DATA}"
fi

# -------- Автозапуск и старт --------
run "Включение автозапуска ${PG_SERVICE}" systemctl enable "${PG_SERVICE}"
run "Старт сервиса ${PG_SERVICE}" systemctl start "${PG_SERVICE}"

# -------- Пароль пользователя postgres --------
if [[ -z "${POSTGRES_PASS}" ]]; then
  POSTGRES_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20 || true)"
fi
run "Установка пароля пользователя postgres" sudo -u postgres "${PG_BIN}/psql" -v ON_ERROR_STOP=1 -d postgres -c "ALTER USER postgres WITH PASSWORD '${POSTGRES_PASS}';"

# -------- Настройка подключения через файл паролей и pg_hba --------
if [[ -f "${PG_HBA}" ]]; then
  log_info "Настройка pg_hba.conf"
  sed -ri 's/^(local\s+all\s+all\s+)(peer|trust)/\1md5/' "${PG_HBA}" || true
  sed -ri 's/^(local\s+all\s+postgres\s+)(peer|trust)/\1md5/' "${PG_HBA}" || true
  grep -qE '^host\s+all\s+all\s+127\.0\.0\.1/32\s+md5' "${PG_HBA}" || echo "host all all 127.0.0.1/32 md5" >> "${PG_HBA}"
  grep -qE '^host\s+all\s+all\s+::1/128\s+md5' "${PG_HBA}" || echo "host all all ::1/128 md5" >> "${PG_HBA}"
  run "Перезагрузка конфигурации PostgreSQL" systemctl reload "${PG_SERVICE}"
fi

# .pgpass для пользователя postgres
# if id postgres >/dev/null 2>&1; then
  # POSTGRES_HOME="$(getent passwd postgres | cut -d: -f6)"
  # PGPASS_FILE="${POSTGRES_HOME}/.pgpass"
  # log_info "Создание .pgpass для пользователя postgres"
  # {
    # echo "localhost:5432:*:postgres:${POSTGRES_PASS}"
    # echo "127.0.0.1:5432:*:postgres:${POSTGRES_PASS}"
    # echo "[::1]:5432:*:postgres:${POSTGRES_PASS}"
  # } > "${PGPASS_FILE}"
  # chown postgres:postgres "${PGPASS_FILE}"
  # chmod 600 "${PGPASS_FILE}"
# fi

# .pgpass для пользователя, под которым выполняется скрипт (root)
EXEC_UID="$(id -u)"
EXEC_HOME="$(getent passwd "${EXEC_UID}" | cut -d: -f6)"
if [[ -n "${EXEC_HOME:-}" && -d "${EXEC_HOME}" ]]; then
  PGPASS_FILE_EXEC="${EXEC_HOME}/.pgpass"
  log_info "Создание .pgpass для текущего пользователя (UID=${EXEC_UID}, HOME=${EXEC_HOME})"
  {
    echo "localhost:5432:*:postgres:${POSTGRES_PASS}"
    echo "127.0.0.1:5432:*:postgres:${POSTGRES_PASS}"
    echo "[::1]:5432:*:postgres:${POSTGRES_PASS}"
  } > "${PGPASS_FILE_EXEC}"
  chown "${EXEC_UID}:${EXEC_UID}" "${PGPASS_FILE_EXEC}" || true
  chmod 600 "${PGPASS_FILE_EXEC}"
fi

log_info "Готово. Версия: ${PGVER}, TZ: ${TIMEZONE}, LANG: ${DEFAULT_LANG}"
echo "Готово. Версия: ${PGVER}, TZ: ${TIMEZONE}, LANG: ${DEFAULT_LANG}"
echo "Пароль пользователя postgres: ${POSTGRES_PASS}"
echo "Лог: ${LOG_FILE} (уровень вывода: ${LOG_LEVEL})"
