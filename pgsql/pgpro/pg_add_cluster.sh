#!/bin/bash
# add_pgpro_instance.sh — добавление нового экземпляра PostgresPro
# Использование: sudo bash add_pgpro_instance.sh [PGPORT] [PGVER]
#                sudo bash add_pgpro_instance.sh          ← интерактивный режим

set -euo pipefail

# ───────────────────────────────────────────────
# ЦВЕТА
# ───────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ───────────────────────────────────────────────
# УТИЛИТЫ
# ───────────────────────────────────────────────
log()     { echo -e "${GREEN}[INFO]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*" >&2; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}$*${RESET}"; }
confirm() {
    # confirm "Вопрос" → 0=да, 1=нет
    local prompt="$1"
    while true; do
        read -rp "$(echo -e "${YELLOW}${prompt}${RESET} [y/n]: ")" ans
        case "${ans,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     echo "Введите y или n." ;;
        esac
    done
}

# ───────────────────────────────────────────────
# СКАНИРОВАНИЕ СУЩЕСТВУЮЩИХ ИНСТАНСОВ
# ───────────────────────────────────────────────
scan_instances() {
    local ver="${1:-1c-18}"
    local defaults_dir="/etc/default"
    local pg_bin="/opt/pgpro/${ver}/bin"

    header "═══ Существующие инстансы PostgresPro-${ver} ═══"

    # Ищем файлы окружения вида postgrespro-<ver>-<port> и postgrespro-<ver>
    local files
    mapfile -t files < <(
        find "${defaults_dir}" -maxdepth 1 \
            -name "postgrespro-${ver}*" \
            ! -name "*.dpkg*" ! -name "*.bak" \
            2>/dev/null | sort
    )

    if [[ ${#files[@]} -eq 0 ]]; then
        warn "Файлы окружения не найдены в ${defaults_dir}"
        return
    fi

    # Шапка таблицы
    printf "${BOLD}%-8s  %-6s  %-45s  %-10s  %-8s${RESET}\n" \
        "СЕРВИС" "ПОРТ" "PGDATA" "СТАТУС" "PID"
    printf '%s\n' "$(printf '─%.0s' {1..85})"

    local found=0
    for f in "${files[@]}"; do
        # Извлекаем PGDATA и PGPORT из файла окружения
        local pgdata pgport svc status pid_str

        pgdata=$(grep -E "^PGDATA=" "$f" 2>/dev/null \
                 | head -1 | sed "s/^PGDATA=//;s/['\"]//g") || pgdata="—"

        # Порт: из имени файла или из PGPORT внутри файла
        local basename
        basename=$(basename "$f")
        if [[ "$basename" =~ -([0-9]{4,5})$ ]]; then
            pgport="${BASH_REMATCH[1]}"
        else
            pgport=$(grep -E "^PGPORT=" "$f" 2>/dev/null \
                     | head -1 | sed "s/^PGPORT=//;s/['\"]//g") || pgport="5432"
        fi

        # Имя сервиса
        if [[ "$pgport" == "5432" ]]; then
            svc="postgrespro-${ver}"
        else
            svc="postgrespro-${ver}@${pgport}"
        fi

        # Статус systemd
        if systemctl is-active --quiet "${svc}" 2>/dev/null; then
            status="${GREEN}running${RESET}"
            # PID мастер-процесса
            pid_str=$(systemctl show -p MainPID "${svc}" 2>/dev/null \
                      | cut -d= -f2) || pid_str="—"
        elif systemctl is-enabled --quiet "${svc}" 2>/dev/null; then
            status="${YELLOW}stopped${RESET}"
            pid_str="—"
        else
            status="${RED}unknown${RESET}"
            pid_str="—"
        fi

        printf "${BOLD}%-8s${RESET}  %-6s  %-45s  %-18s  %-8s\n" \
            "${svc##postgrespro-${ver}}" \
            "${pgport}" \
            "${pgdata}" \
            "$(echo -e "${status}")" \
            "${pid_str}"

        (( found++ )) || true
    done

    printf '%s\n' "$(printf '─%.0s' {1..85})"
    echo -e "Итого: ${BOLD}${found}${RESET} инстанс(ов)\n"
}

# ───────────────────────────────────────────────
# ИНТЕРАКТИВНЫЙ ВВОД
# ───────────────────────────────────────────────
interactive_mode() {
    header "═══ Интерактивное добавление инстанса PostgresPro ═══"

    # PGVER
    read -rp "$(echo -e "${CYAN}Версия PostgresPro${RESET} [1c-18]: ")" input_ver
    PGVER="${input_ver:-1c-18}"

    # Показываем таблицу ПОСЛЕ выбора версии
    scan_instances "${PGVER}"

    # PGPORT
    while true; do
        read -rp "$(echo -e "${CYAN}Порт для нового инстанса${RESET} [5433]: ")" input_port
        PGPORT="${input_port:-5433}"
        if ! [[ "$PGPORT" =~ ^[0-9]{4,5}$ ]]; then
            warn "Некорректный порт: ${PGPORT}"
            continue
        fi
        if ss -tlnp | grep -q ":${PGPORT} "; then
            warn "Порт ${PGPORT} уже занят — выберите другой."
            continue
        fi
        break
    done

    # PGDATA
    local default_data="/var/lib/pgpro/${PGVER}/data-${PGPORT}"
    read -rp "$(echo -e "${CYAN}Каталог данных${RESET} [${default_data}]: ")" input_data
    PGDATA_NEW="${input_data:-${default_data}}"

    # Пароль
    read -rsp "$(echo -e "${CYAN}Пароль суперпользователя${RESET} (Enter = пропустить): ")" PGPASSWORD
    echo ""

    # Подтверждение
    echo ""
    echo -e "${BOLD}Параметры нового инстанса:${RESET}"
    printf "  %-12s %s\n" "Версия:"   "${PGVER}"
    printf "  %-12s %s\n" "Порт:"     "${PGPORT}"
    printf "  %-12s %s\n" "PGDATA:"   "${PGDATA_NEW}"
    printf "  %-12s %s\n" "Пароль:"   "${PGPASSWORD:+(задан)}"
    echo ""

    confirm "Продолжить создание инстанса?" || { echo "Отменено."; exit 0; }
}

# ───────────────────────────────────────────────
# ПАРАМЕТРЫ (авто или интерактив)
# ───────────────────────────────────────────────
PGPORT=""
PGVER="1c-18"
PGPASSWORD=""
PGDATA_NEW=""

if [[ $# -eq 0 ]]; then
    INTERACTIVE=1
else
    INTERACTIVE=0
    PGPORT="${1:-5433}"
    PGVER="${2:-1c-18}"
    PGPASSWORD="${3:-}"
fi

# ───────────────────────────────────────────────
# ЗАВИСИМЫЕ ПЕРЕМЕННЫЕ (заполняются после ввода)
# ───────────────────────────────────────────────
setup_vars() {
    PGDATA_BASE="/var/lib/pgpro/${PGVER}"
    PGDATA_NEW="${PGDATA_NEW:-${PGDATA_BASE}/data-${PGPORT}}"
    PG_BIN="/opt/pgpro/${PGVER}/bin"

    SYSTEMD_DIR="/lib/systemd/system"
    DEFAULTS_DIR="/etc/default"

    SVC_BASE="postgrespro-${PGVER}"
    SVC_TEMPLATE="${SVC_BASE}@.service"
    SVC_INSTANCE="${SVC_BASE}@${PGPORT}"

    ENV_BASE="${DEFAULTS_DIR}/${SVC_BASE}"
    ENV_NEW="${DEFAULTS_DIR}/${SVC_BASE}-${PGPORT}"
    OVERRIDE_DIR="/etc/systemd/system/${SVC_INSTANCE}.service.d"
}

# ───────────────────────────────────────────────
# ТОЧКА ВХОДА
# ───────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Запустите скрипт от root (sudo)."

if [[ $INTERACTIVE -eq 1 ]]; then
    interactive_mode   # внутри уже вызывает scan_instances
else
    # В автоматическом режиме — сразу показываем таблицу
    scan_instances "${PGVER}"
fi

setup_vars

# ───────────────────────────────────────────────
# ПРОВЕРКИ
# ───────────────────────────────────────────────
header "Проверка предусловий..."

# Ищем базовый unit: обычный или шаблонный
BASE_UNIT=""
for candidate in \
    "${SYSTEMD_DIR}/${SVC_BASE}.service" \
    "${SYSTEMD_DIR}/${SVC_TEMPLATE}" \
    "/usr/lib/systemd/system/${SVC_BASE}.service" \
    "/usr/lib/systemd/system/${SVC_TEMPLATE}"; do
    if [[ -f "$candidate" ]]; then
        BASE_UNIT="$candidate"
        break
    fi
done
[[ -n "$BASE_UNIT" ]] || die "Базовый unit не найден. Проверьте установку pgpro."
log "Базовый unit: ${BASE_UNIT}"

[[ -f "${ENV_BASE}" ]]    || die "Файл окружения не найден: ${ENV_BASE}"
[[ -x "${PG_BIN}/initdb" ]] || die "initdb не найден: ${PG_BIN}/initdb"

ss -tlnp | grep -q ":${PGPORT} " \
    && die "Порт ${PGPORT} уже занят."

if [[ -d "${PGDATA_NEW}" && -n "$(ls -A "${PGDATA_NEW}" 2>/dev/null)" ]]; then
    die "Каталог данных уже существует и не пуст: ${PGDATA_NEW}"
fi

systemctl is-active --quiet "${SVC_INSTANCE}" \
    && die "Сервис ${SVC_INSTANCE} уже запущен."

log "Все проверки пройдены."

# ───────────────────────────────────────────────
# ШАГ 1: Шаблон systemd-юнита
# ───────────────────────────────────────────────
header "Шаг 1: Создание шаблонного unit-файла..."

if [[ ! -f "${SYSTEMD_DIR}/${SVC_TEMPLATE}" ]]; then
    cp "${BASE_UNIT}" "${SYSTEMD_DIR}/${SVC_TEMPLATE}"
    # Убираем WantedBy из шаблона, чтобы не конфликтовал
    sed -i '/^WantedBy=/d' "${SYSTEMD_DIR}/${SVC_TEMPLATE}"
    log "Создан шаблон: ${SYSTEMD_DIR}/${SVC_TEMPLATE}"
else
    log "Шаблон уже существует, пропускаем."
fi

# ───────────────────────────────────────────────
# ШАГ 2: Файл окружения
# ───────────────────────────────────────────────
header "Шаг 2: Файл окружения ${ENV_NEW}..."

[[ -f "${ENV_NEW}" ]] && warn "Перезаписываем существующий ${ENV_NEW}"
cp "${ENV_BASE}" "${ENV_NEW}"
sed -i "s#^PGDATA=.*#PGDATA='${PGDATA_NEW}'#" "${ENV_NEW}"
log "PGDATA → ${PGDATA_NEW}"

# ───────────────────────────────────────────────
# ШАГ 3: Override
# ───────────────────────────────────────────────
header "Шаг 3: Override для ${SVC_INSTANCE}..."

mkdir -p "${OVERRIDE_DIR}"
cat > "${OVERRIDE_DIR}/override.conf" <<EOF
[Unit]
Description=Postgres Pro ${PGVER} database server on port %I

[Service]
EnvironmentFile=/etc/default/postgrespro-${PGVER}-%I
Environment=PGPORT=%I
EOF
log "Override записан: ${OVERRIDE_DIR}/override.conf"

# ───────────────────────────────────────────────
# ШАГ 4: daemon-reload
# ───────────────────────────────────────────────
header "Шаг 4: daemon-reload..."
systemctl daemon-reload
log "Готово."

# ───────────────────────────────────────────────
# ШАГ 5: Инициализация кластера
# ───────────────────────────────────────────────
header "Шаг 5: Инициализация кластера в ${PGDATA_NEW}..."

mkdir -p "${PGDATA_NEW}"
chown postgres:postgres "${PGDATA_NEW}"
chmod 700 "${PGDATA_NEW}"

su - postgres -c \
    "${PG_BIN}/initdb --tune=1c --locale=ru_RU.UTF-8 --pgdata='${PGDATA_NEW}'"
log "Инициализация завершена."

# ───────────────────────────────────────────────
# ШАГ 6: Запуск и автозагрузка
# ───────────────────────────────────────────────
header "Шаг 6: Запуск и автозагрузка..."

systemctl start  "${SVC_INSTANCE}"
systemctl enable "${SVC_INSTANCE}"

TIMEOUT=30; ELAPSED=0
until su - postgres -c "${PG_BIN}/pg_isready -p ${PGPORT}" &>/dev/null; do
    sleep 1; (( ELAPSED++ )) || true
    [[ ${ELAPSED} -lt ${TIMEOUT} ]] \
        || die "Сервис не поднялся за ${TIMEOUT}с. Проверьте: journalctl -u ${SVC_INSTANCE}"
done
log "Инстанс отвечает на порту ${PGPORT}."

# ───────────────────────────────────────────────
# ШАГ 7: Пароль суперпользователя
# ───────────────────────────────────────────────
if [[ -n "${PGPASSWORD}" ]]; then
    header "Шаг 7: Установка пароля..."
    su - postgres -c \
        "${PG_BIN}/psql -p ${PGPORT} -c \"ALTER USER postgres WITH PASSWORD '${PGPASSWORD}';\""
    log "Пароль установлен."
else
    warn "Пароль не задан. Установите вручную:"
    echo "  su - postgres -c \"${PG_BIN}/psql -p ${PGPORT} -c \\\"ALTER USER postgres WITH PASSWORD 'pass';\\\"\""
fi

# ───────────────────────────────────────────────
# ИТОГ + обновлённая таблица всех инстансов
# ───────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}════════════════════════════════════════════${RESET}"
echo -e "${BOLD}${GREEN} ✅  Инстанс успешно создан${RESET}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════════${RESET}"
printf "  ${BOLD}%-12s${RESET} %s\n" "Версия:"  "${PGVER}"
printf "  ${BOLD}%-12s${RESET} %s\n" "Порт:"    "${PGPORT}"
printf "  ${BOLD}%-12s${RESET} %s\n" "PGDATA:"  "${PGDATA_NEW}"
printf "  ${BOLD}%-12s${RESET} %s\n" "Сервис:"  "${SVC_INSTANCE}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════════${RESET}\n"

echo "Полезные команды:"
echo "  systemctl status ${SVC_INSTANCE}"
echo "  journalctl -u ${SVC_INSTANCE} -f"
echo "  su - postgres -c \"${PG_BIN}/psql -p ${PGPORT}\""

# Финальная таблица всех инстансов
scan_instances "${PGVER}"
