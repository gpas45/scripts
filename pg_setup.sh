#!/usr/bin/env bash
set -euo pipefail

# -------- Параметры (можно переопределить аргументами/переменными окружения) --------
PGVER="${PGVER:-1c-18}"                       # пример: 1c-18
TIMEZONE="${TIMEZONE:-Asia/Yekaterinburg}"
DEFAULT_LANG="${DEFAULT_LANG:-ru_RU.UTF-8}"   # ru_RU.UTF-8 по умолчанию
LOCALES=("ru_RU.UTF-8" "en_US.UTF-8")
BASHRC_URL="${BASHRC_URL:-https://raw.githubusercontent.com/RomNero/YouTube-Infos/main/Linux-System-Configs/.bashrc}"
POSTGRES_PASS="${POSTGRES_PASS:-}"             # можно передать заранее, иначе сгенерируется

# -------- Аргументы --------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pgver) PGVER="$2"; shift 2;;
    --timezone) TIMEZONE="$2"; shift 2;;
    --lang|--default-lang) DEFAULT_LANG="$2"; shift 2;;
    --postgres-pass) POSTGRES_PASS="$2"; shift 2;;
    -h|--help)
      echo "Usage: sudo $0 [--pgver 1c-18] [--timezone Asia/Yekaterinburg] [--default-lang ru_RU.UTF-8] [--postgres-pass PASS]"
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

# -------- Обновление системы и базовые пакеты --------
apt-get update -y
apt-get -o Dpkg::Options::="--force-confnew" dist-upgrade -y
apt-get install -y mc nano console-setup net-tools htop tmux curl ca-certificates gnupg lsb-release locales

# -------- Локали --------
for L in "${LOCALES[@]}"; do
  grep -qE "^${L}\s+UTF-8" /etc/locale.gen 2>/dev/null || echo "${L} UTF-8" >> /etc/locale.gen
done
locale-gen
update-locale LANG="${DEFAULT_LANG}"

# -------- Часовой пояс --------
if command -v timedatectl >/dev/null 2>&1; then
  timedatectl set-timezone "${TIMEZONE}"
else
  ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
  dpkg-reconfigure -f noninteractive tzdata
fi

# -------- Настройка консоли (console-setup) --------
{
  sed -i 's/^XKBMODEL=.*/XKBMODEL="pc105"/' /etc/default/keyboard || true
  grep -q "^XKBMODEL=" /etc/default/keyboard || echo 'XKBMODEL="pc105"' >> /etc/default/keyboard

  sed -i 's/^XKBLAYOUT=.*/XKBLAYOUT="ru,us"/' /etc/default/keyboard || true
  grep -q "^XKBLAYOUT=" /etc/default/keyboard || echo 'XKBLAYOUT="ru,us"' >> /etc/default/keyboard

  sed -i 's/^XKBVARIANT=.*/XKBVARIANT=","/' /etc/default/keyboard || true
  grep -q "^XKBVARIANT=" /etc/default/keyboard || echo 'XKBVARIANT=","' >> /etc/default/keyboard

  sed -i 's/^XKBOPTIONS=.*/XKBOPTIONS="grp:alt_shift_toggle"/' /etc/default/keyboard || true
  grep -q "^XKBOPTIONS=" /etc/default/keyboard || echo 'XKBOPTIONS="grp:alt_shift_toggle"' >> /etc/default/keyboard
} || true

cat >/etc/default/console-setup <<'EOF'
ACTIVE_CONSOLES="/dev/tty[1-6]"
CHARMAP="UTF-8"
CODESET="guess"
FONTFACE="TerminusBold"
FONTSIZE="8x16"
EOF

service keyboard-setup restart || true
setupcon -k || true

# -------- .bashrc для окружения bash --------
curl -fsSL "${BASHRC_URL}" -o /etc/skel/.bashrc
install -m 0644 /etc/skel/.bashrc /root/.bashrc
if id postgres >/dev/null 2>&1; then
  POSTGRES_HOME="$(getent passwd postgres | cut -d: -f6)"
  install -o postgres -g postgres -m 0644 /etc/skel/.bashrc "${POSTGRES_HOME}/.bashrc"
fi

# -------- Репозиторий Postgres Pro 1C (версия параметризуется) --------
REPO_SCRIPT_URL="https://repo.postgrespro.ru/${PGVER}/keys/pgpro-repo-add.sh"
curl -fsSL "${REPO_SCRIPT_URL}" -o /tmp/pgpro-repo-add.sh
bash /tmp/pgpro-repo-add.sh
apt-get update -y

# -------- Установка Postgres Pro 1C --------
apt-get install -y "postgrespro-${PGVER}"

# -------- Заморозка пакетов (hold) --------
# Общие пакеты
apt-mark hold postgresql-common postgresql-client-common || true
apt-mark hold libpq5 || true
# Пакеты текущей версии Postgres Pro 1C
apt-mark hold "postgrespro-${PGVER}" \
               "postgrespro-${PGVER}-client" \
               "postgrespro-${PGVER}-contrib" \
               "postgrespro-${PGVER}-libs" \
               "postgrespro-${PGVER}-server" || true

# -------- Символические ссылки через pg-wrapper --------
"${PG_BIN}/pg-wrapper" links update

# -------- Старт/стоп для проверки, затем очистка каталога --------
systemctl start "${PG_SERVICE}" || true
if systemctl is-active --quiet "${PG_SERVICE}"; then
  systemctl stop "${PG_SERVICE}"
fi

rm -rf "${PG_DATA}"

# -------- Инициализация кластера для 1С с нужной локалью --------
"${PG_BIN}/pg-setup" initdb --tune=1c --locale="${DEFAULT_LANG}"

# -------- (Опционально) настройки для 1С: UNIX-сокет --------


# -------- Включение контрольных сумм, если версия < 18 --------
if [[ "${PG_MAJOR}" =~ ^[0-9]+$ ]] && [[ "${PG_MAJOR}" -lt 18 ]]; then
  "${PG_BIN}/pg_checksums" --enable -D "${PG_DATA}"
fi

# -------- Автозапуск и старт --------
systemctl enable "${PG_SERVICE}"
systemctl start "${PG_SERVICE}"

# Если меняли UNIX-сокеты для 1С — перезапустим для применения (после старта)

# -------- Пароль пользователя postgres --------
if [[ -z "${POSTGRES_PASS}" ]]; then
  POSTGRES_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20 || true)"
fi
sudo -u postgres "${PG_BIN}/psql" -v ON_ERROR_STOP=1 -d postgres -c "ALTER USER postgres WITH PASSWORD '${POSTGRES_PASS}';"

# -------- Настройка подключения через файл паролей и pg_hba --------
if [[ -f "${PG_HBA}" ]]; then
  sed -ri 's/^(local\s+all\s+all\s+)(peer|trust)/\1md5/' "${PG_HBA}" || true
  sed -ri 's/^(local\s+all\s+postgres\s+)(peer|trust)/\1md5/' "${PG_HBA}" || true
  grep -qE '^host\s+all\s+all\s+127\.0\.0\.1/32\s+md5' "${PG_HBA}" || echo "host all all 127.0.0.1/32 md5" >> "${PG_HBA}"
  grep -qE '^host\s+all\s+all\s+::1/128\s+md5' "${PG_HBA}" || echo "host all all ::1/128 md5" >> "${PG_HBA}"
  systemctl reload "${PG_SERVICE}"
fi

# .pgpass для пользователя postgres
if id postgres >/dev/null 2>&1; then
  POSTGRES_HOME="$(getent passwd postgres | cut -d: -f6)"
  PGPASS_FILE="${POSTGRES_HOME}/.pgpass"
  {
    echo "localhost:5432:*:postgres:${POSTGRES_PASS}"
    echo "127.0.0.1:5432:*:postgres:${POSTGRES_PASS}"
    echo "[::1]:5432:*:postgres:${POSTGRES_PASS}"
  } > "${PGPASS_FILE}"
  chown postgres:postgres "${PGPASS_FILE}"
  chmod 600 "${PGPASS_FILE}"
fi

echo "Готово. Версия: ${PGVER}, TZ: ${TIMEZONE}, LANG: ${DEFAULT_LANG}"
echo "Пароль пользователя postgres: ${POSTGRES_PASS}"
