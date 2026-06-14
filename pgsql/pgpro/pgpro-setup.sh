#!/usr/bin/env bash
# pgpro-setup.sh — установка Postgres Pro (для 1С) с выбором версии
#                  и добавлением дополнительных экземпляров.
#
# Сделано строго по статье wiki.dioservice.ru
# («Установка Postgres Pro 1C 18 в LXC (Debian 13)»).
#
# Режимы:
#   sudo ./pgpro-setup.sh                 ← интерактивное меню
#   sudo ./pgpro-setup.sh install         ← установка (спросит версию)
#   sudo ./pgpro-setup.sh add-instance    ← добавить экземпляр
#   sudo ./pgpro-setup.sh list            ← список экземпляров
#
# Переменные окружения (можно переопределить):
#   PGVER         версия, напр. 1c-18 (по умолчанию спрашивается)
#   TIMEZONE      часовой пояс           (Asia/Yekaterinburg)
#   PG_LOCALE     локаль кластера        (ru_RU.UTF-8)
#   POSTGRES_PASS пароль суперпользователя (иначе сгенерируется)

set -euo pipefail

# ───────────────────────────────────────────────
# ЦВЕТА И ЛОГИ
# ───────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()    { echo -e "${GREEN}[INFO]${RESET}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*" >&2; }
die()    { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
header() { echo -e "\n${BOLD}${CYAN}$*${RESET}"; }

confirm() {
    # confirm "Вопрос" → 0=да, 1=нет
    local prompt="$1"
    while true; do
        read -rp "$(echo -e "${YELLOW}${prompt}${RESET} [y/n]: ")" ans
        case "${ans,,}" in
            y|yes|д|да) return 0 ;;
            n|no|н|нет) return 1 ;;
            *)          echo "Введите y или n." ;;
        esac
    done
}

# ───────────────────────────────────────────────
# ПАРАМЕТРЫ ПО УМОЛЧАНИЮ
# ───────────────────────────────────────────────
PGVER="${PGVER:-}"
TIMEZONE="${TIMEZONE:-Asia/Yekaterinburg}"
PG_LOCALE="${PG_LOCALE:-ru_RU.UTF-8}"
POSTGRES_PASS="${POSTGRES_PASS:-}"

# Часто используемые версии Postgres Pro 1C (для меню выбора)
SUGGESTED_VERSIONS=("1c-18" "1c-17" "1c-16" "1c-15" "1c-14")

# ───────────────────────────────────────────────
# ОБЩИЕ ПРОВЕРКИ
# ───────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || die "Запустите скрипт от root (sudo)."
}

require_debian() {
    [[ -r /etc/os-release ]] || die "Не найден /etc/os-release."
    # shellcheck disable=SC1091
    . /etc/os-release
    if ! echo "${ID_LIKE:-$ID}" | tr '[:upper:]' '[:lower:]' | grep -Eq 'debian|ubuntu'; then
        die "Скрипт рассчитан на Debian/Ubuntu."
    fi
}

# Мажорный номер из версии: 1c-18 → 18
pg_major() {
    echo "${1}" | sed -E 's/.*-([0-9]+).*/\1/'
}

# Пути по версии
pg_bin()  { echo "/opt/pgpro/${1}/bin"; }
pg_data() { echo "/var/lib/pgpro/${1}/data"; }

# ───────────────────────────────────────────────
# ВЫБОР ВЕРСИИ
# ───────────────────────────────────────────────
choose_version() {
    # Если версия уже задана через окружение/аргумент — не спрашиваем.
    if [[ -n "${PGVER}" ]]; then
        log "Версия Postgres Pro: ${BOLD}${PGVER}${RESET}"
        return
    fi

    header "═══ Выбор версии Postgres Pro ═══"
    local i=1
    for v in "${SUGGESTED_VERSIONS[@]}"; do
        printf "  ${BOLD}%2d${RESET}) %s\n" "$i" "$v"
        (( i++ )) || true
    done
    printf "  ${BOLD}%2d${RESET}) ввести вручную (напр. std-17, ent-16)\n" "$i"

    local choice ver
    while true; do
        read -rp "$(echo -e "${CYAN}Выберите версию${RESET} [1]: ")" choice
        choice="${choice:-1}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#SUGGESTED_VERSIONS[@]} )); then
            ver="${SUGGESTED_VERSIONS[choice-1]}"
            break
        elif [[ "$choice" -eq $i ]]; then
            read -rp "$(echo -e "${CYAN}Введите версию${RESET} (формат edition-major, напр. 1c-18): ")" ver
            [[ -n "$ver" ]] && break
        else
            warn "Некорректный выбор."
        fi
    done
    PGVER="$ver"
    log "Выбрана версия: ${BOLD}${PGVER}${RESET}"
}

# Версия уже установлена? (используется в add-instance/list)
detect_installed_version() {
    # Если PGVER не задан — пытаемся определить по /opt/pgpro.
    if [[ -n "${PGVER}" ]]; then
        return
    fi
    local dirs=()
    mapfile -t dirs < <(find /opt/pgpro -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
    if [[ ${#dirs[@]} -eq 0 ]]; then
        die "Не найдено ни одной установки в /opt/pgpro. Сначала выполните install."
    elif [[ ${#dirs[@]} -eq 1 ]]; then
        PGVER="${dirs[0]}"
        log "Обнаружена установленная версия: ${BOLD}${PGVER}${RESET}"
    else
        header "Обнаружено несколько установок Postgres Pro:"
        local i=1
        for d in "${dirs[@]}"; do printf "  ${BOLD}%2d${RESET}) %s\n" "$i" "$d"; (( i++ )) || true; done
        local choice
        read -rp "$(echo -e "${CYAN}Выберите версию${RESET} [1]: ")" choice
        choice="${choice:-1}"
        PGVER="${dirs[choice-1]:-${dirs[0]}}"
        log "Выбрана версия: ${BOLD}${PGVER}${RESET}"
    fi
}

# ───────────────────────────────────────────────
# СПИСОК ЭКЗЕМПЛЯРОВ
# ───────────────────────────────────────────────
list_instances() {
    local ver="${1}"
    header "═══ Экземпляры Postgres Pro-${ver} ═══"

    local files=()
    mapfile -t files < <(
        find /etc/default -maxdepth 1 -name "postgrespro-${ver}*" \
            ! -name "*.dpkg*" ! -name "*.bak" 2>/dev/null | sort
    )
    if [[ ${#files[@]} -eq 0 ]]; then
        warn "Файлы окружения не найдены в /etc/default — экземпляров нет."
        return
    fi

    printf "${BOLD}%-22s  %-6s  %-40s  %-9s${RESET}\n" "СЕРВИС" "ПОРТ" "PGDATA" "СТАТУС"
    printf '%s\n' "$(printf '─%.0s' {1..82})"

    local f base pgdata pgport svc status
    for f in "${files[@]}"; do
        pgdata=$(grep -E "^PGDATA=" "$f" 2>/dev/null | head -1 | sed "s/^PGDATA=//;s/['\"]//g")
        base=$(basename "$f")
        if [[ "$base" =~ -([0-9]{4,5})$ ]]; then
            pgport="${BASH_REMATCH[1]}"
            svc="postgrespro-${ver}@${pgport}"
        else
            pgport="5432"
            svc="postgrespro-${ver}"
        fi
        if systemctl is-active --quiet "${svc}" 2>/dev/null; then
            status="${GREEN}running${RESET}"
        elif systemctl is-enabled --quiet "${svc}" 2>/dev/null; then
            status="${YELLOW}stopped${RESET}"
        else
            status="${RED}unknown${RESET}"
        fi
        printf "%-22s  %-6s  %-40s  %b\n" "${svc}" "${pgport}" "${pgdata:-—}" "${status}"
    done
    printf '%s\n' "$(printf '─%.0s' {1..82})"
    echo ""
}

# ───────────────────────────────────────────────
# ШАГ: ПОДГОТОВКА ОС (локали, TZ, консоль)
# ───────────────────────────────────────────────
prepare_os() {
    header "Подготовка системы: пакеты, локали, время, консоль"
    export DEBIAN_FRONTEND=noninteractive

    log "Обновление системы"
    apt-get update -y
    apt-get -o Dpkg::Options::="--force-confnew" upgrade -y
    apt-get install -y mc nano console-setup net-tools htop \
        curl wget ca-certificates gnupg lsb-release locales

    # Локали (ru_RU.UTF-8 + en_US.UTF-8) — неинтерактивный аналог dpkg-reconfigure locales
    log "Генерация локалей ru_RU.UTF-8 / en_US.UTF-8"
    local L
    for L in "ru_RU.UTF-8" "en_US.UTF-8"; do
        grep -qE "^${L} UTF-8" /etc/locale.gen 2>/dev/null || echo "${L} UTF-8" >> /etc/locale.gen
    done
    locale-gen
    update-locale LANG="ru_RU.UTF-8"

    # Часовой пояс
    log "Часовой пояс: ${TIMEZONE}"
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-timezone "${TIMEZONE}" || warn "Не удалось задать TZ через timedatectl"
    else
        ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
    fi

    # Консоль (console-setup) — как в статье
    log "Настройка консоли (console-setup)"
    cat > /etc/default/console-setup <<'EOF'
ACTIVE_CONSOLES="/dev/tty[1-6]"
CHARMAP="UTF-8"
CODESET="guess"
FONTFACE="TerminusBold"
FONTSIZE="8x16"
EOF
    setupcon -k >/dev/null 2>&1 || true
}

# ───────────────────────────────────────────────
# ШАГ: ОТКЛЮЧЕНИЕ IPv6 (раздел «Дополнительная настройка»)
# ───────────────────────────────────────────────
disable_ipv6() {
    header "Отключение IPv6"
    cat > /etc/sysctl.d/00-ipv6-disable.conf <<'EOF'
# Отключение IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    sysctl -p /etc/sysctl.d/00-ipv6-disable.conf >/dev/null 2>&1 || true
    log "IPv6 отключён (/etc/sysctl.d/00-ipv6-disable.conf)."
}

# ───────────────────────────────────────────────
# КОМАНДА: УСТАНОВКА
# ───────────────────────────────────────────────
cmd_install() {
    require_root
    require_debian
    choose_version

    local PG_BIN PG_DATA PG_MAJOR PG_SERVICE
    PG_BIN="$(pg_bin "${PGVER}")"
    PG_DATA="$(pg_data "${PGVER}")"
    PG_MAJOR="$(pg_major "${PGVER}")"
    PG_SERVICE="postgrespro-${PGVER}"

    # Предупреждение, если уже установлено
    if [[ -x "${PG_BIN}/postgres" ]]; then
        warn "Postgres Pro ${PGVER} уже установлен (${PG_BIN})."
        confirm "Продолжить всё равно?" || { log "Отменено."; exit 0; }
    fi

    # Доп. шаги (по умолчанию включены, как было выбрано)
    local DO_OS=1 DO_IPV6=1
    if [[ -t 0 ]]; then
        confirm "Выполнить подготовку ОС (локали, TZ, консоль)?" && DO_OS=1 || DO_OS=0
        confirm "Отключить IPv6?" && DO_IPV6=1 || DO_IPV6=0
    fi
    [[ "${DO_OS}" -eq 1 ]] && prepare_os

    # ── Репозиторий и пакеты ──
    header "Подключение репозитория Postgres Pro ${PGVER} и установка"
    local repo_url="https://repo.postgrespro.ru/${PGVER}/keys/pgpro-repo-add.sh"
    log "Загрузка скрипта репозитория: ${repo_url}"
    wget -qO /tmp/pgpro-repo-add.sh "${repo_url}" \
        || die "Не удалось скачать ${repo_url}. Проверьте имя версии (${PGVER})."
    sh /tmp/pgpro-repo-add.sh
    rm -f /tmp/pgpro-repo-add.sh
    apt-get update -y

    log "Установка пакета postgrespro-${PGVER}"
    apt-get install -y "postgrespro-${PGVER}"

    # Фиксация версий пакетов
    log "Фиксация версий пакетов (apt-mark hold)"
    apt-mark hold postgresql-common postgresql-client-common >/dev/null 2>&1 || true
    apt-mark hold libpq5 \
        "postgrespro-${PGVER}" "postgrespro-${PGVER}-client" \
        "postgrespro-${PGVER}-contrib" "postgrespro-${PGVER}-libs" \
        "postgrespro-${PGVER}-server" >/dev/null 2>&1 || true

    # Симлинки бинарников
    log "Обновление симлинков (pg-wrapper links update)"
    "${PG_BIN}/pg-wrapper" links update

    # Первый старт/проверка/стоп
    header "Первичная инициализация кластера"
    log "Пробный старт службы ${PG_SERVICE}"
    systemctl start "${PG_SERVICE}" || true
    systemctl is-active --quiet "${PG_SERVICE}" && systemctl stop "${PG_SERVICE}"

    log "Очистка каталога данных ${PG_DATA}"
    rm -rf "${PG_DATA}"

    # initdb с настройкой под 1С
    log "Инициализация: initdb --tune=1c --locale=${PG_LOCALE}"
    "${PG_BIN}/pg-setup" initdb --tune=1c --locale="${PG_LOCALE}"

    # Контрольные суммы страниц: PG 10–16 включаем вручную, 17+ уже по умолчанию
    if [[ "${PG_MAJOR}" =~ ^[0-9]+$ ]] && (( PG_MAJOR < 17 )); then
        log "Включение контрольных сумм страниц (PG ${PG_MAJOR} < 17)"
        "${PG_BIN}/pg_checksums" --enable -D "${PG_DATA}"
    else
        log "Контрольные суммы включены по умолчанию (PG ${PG_MAJOR} ≥ 17)"
    fi

    # Автозапуск и старт
    log "Автозапуск и старт службы ${PG_SERVICE}"
    systemctl enable "${PG_SERVICE}"
    systemctl start "${PG_SERVICE}"

    # Пароль суперпользователя
    if [[ -z "${POSTGRES_PASS}" ]]; then
        POSTGRES_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20 || true)"
        log "Сгенерирован пароль пользователя postgres."
    fi
    su - postgres -c "${PG_BIN}/psql -v ON_ERROR_STOP=1 -c \"ALTER USER postgres WITH PASSWORD '${POSTGRES_PASS}';\""

    # pg_hba: метод scram-sha-256 (как в статье)
    local PG_HBA="${PG_DATA}/pg_hba.conf"
    if [[ -f "${PG_HBA}" ]]; then
        log "Настройка pg_hba.conf (scram-sha-256)"
        sed -ri 's/^(local\s+all\s+all\s+)(peer|trust|md5|ident)\b/\1scram-sha-256/' "${PG_HBA}"
        sed -ri 's/^(host\s+all\s+all\s+127\.0\.0\.1\/32\s+)(trust|md5|ident)\b/\1scram-sha-256/' "${PG_HBA}"
        su - postgres -c "${PG_BIN}/psql -c 'SELECT pg_reload_conf();'" >/dev/null
    fi

    # .pgpass для текущего (вызвавшего) пользователя
    local exec_home pgpass
    exec_home="$(getent passwd "$(id -u)" | cut -d: -f6)"
    if [[ -n "${exec_home}" && -d "${exec_home}" ]]; then
        pgpass="${exec_home}/.pgpass"
        log "Создание ${pgpass}"
        cat > "${pgpass}" <<EOF
#hostname:port:database:username:password
localhost:5432:postgres:postgres:${POSTGRES_PASS}
EOF
        chmod 600 "${pgpass}"
        chown "$(id -u):$(id -g)" "${pgpass}" || true
    fi

    [[ "${DO_IPV6}" -eq 1 ]] && disable_ipv6

    header "✅ Установка Postgres Pro ${PGVER} завершена"
    printf "  ${BOLD}%-14s${RESET} %s\n" "Версия:"  "${PGVER}"
    printf "  ${BOLD}%-14s${RESET} %s\n" "Служба:"  "${PG_SERVICE}"
    printf "  ${BOLD}%-14s${RESET} %s\n" "PGDATA:"  "${PG_DATA}"
    printf "  ${BOLD}%-14s${RESET} %s\n" "Локаль:"  "${PG_LOCALE}"
    printf "  ${BOLD}%-14s${RESET} %s\n" "Пароль postgres:" "${POSTGRES_PASS}"
    echo ""
    echo "Проверка: systemctl status ${PG_SERVICE}"
    echo "Подключение: su - postgres -c \"${PG_BIN}/psql\""
}

# ───────────────────────────────────────────────
# КОМАНДА: ДОБАВИТЬ ЭКЗЕМПЛЯР
# ───────────────────────────────────────────────
cmd_add_instance() {
    require_root
    require_debian
    detect_installed_version

    local PG_BIN PGPORT PGDATA_NEW
    PG_BIN="$(pg_bin "${PGVER}")"
    [[ -x "${PG_BIN}/initdb" ]] || die "initdb не найден: ${PG_BIN}/initdb (версия установлена?)"

    list_instances "${PGVER}"

    # Порт
    while true; do
        read -rp "$(echo -e "${CYAN}Порт нового экземпляра${RESET} [5433]: ")" PGPORT
        PGPORT="${PGPORT:-5433}"
        if ! [[ "$PGPORT" =~ ^[0-9]{4,5}$ ]]; then
            warn "Некорректный порт: ${PGPORT}"; continue
        fi
        if ss -tlnp 2>/dev/null | grep -q ":${PGPORT} "; then
            warn "Порт ${PGPORT} уже занят."; continue
        fi
        break
    done

    # Каталог данных
    local default_data="/var/lib/pgpro/${PGVER}/data-${PGPORT}"
    read -rp "$(echo -e "${CYAN}Каталог данных${RESET} [${default_data}]: ")" PGDATA_NEW
    PGDATA_NEW="${PGDATA_NEW:-${default_data}}"
    if [[ -d "${PGDATA_NEW}" && -n "$(ls -A "${PGDATA_NEW}" 2>/dev/null)" ]]; then
        die "Каталог данных существует и не пуст: ${PGDATA_NEW}"
    fi

    # Пароль
    local INST_PASS
    read -rsp "$(echo -e "${CYAN}Пароль суперпользователя${RESET} (Enter = пропустить): ")" INST_PASS
    echo ""

    # Переменные служб
    local SVC_BASE="postgrespro-${PGVER}"
    local SVC_TEMPLATE="${SVC_BASE}@.service"
    local SVC_INSTANCE="${SVC_BASE}@${PGPORT}"
    local ENV_BASE="/etc/default/${SVC_BASE}"
    local ENV_NEW="/etc/default/${SVC_BASE}-${PGPORT}"
    local OVERRIDE_DIR="/etc/systemd/system/${SVC_INSTANCE}.service.d"

    # Базовый unit
    local BASE_UNIT=""
    local c
    for c in "/lib/systemd/system/${SVC_BASE}.service" \
             "/usr/lib/systemd/system/${SVC_BASE}.service"; do
        [[ -f "$c" ]] && { BASE_UNIT="$c"; break; }
    done
    [[ -n "$BASE_UNIT" ]] || die "Базовый unit ${SVC_BASE}.service не найден."
    [[ -f "${ENV_BASE}" ]] || die "Файл окружения ${ENV_BASE} не найден."

    echo ""
    echo -e "${BOLD}Параметры нового экземпляра:${RESET}"
    printf "  %-12s %s\n" "Версия:" "${PGVER}"
    printf "  %-12s %s\n" "Порт:"   "${PGPORT}"
    printf "  %-12s %s\n" "PGDATA:" "${PGDATA_NEW}"
    echo ""
    confirm "Создать экземпляр?" || { log "Отменено."; exit 0; }

    # ── Шаг 1: шаблон unit ──
    header "Шаг 1: шаблонный unit ${SVC_TEMPLATE}"
    if [[ ! -f "/lib/systemd/system/${SVC_TEMPLATE}" ]]; then
        cp "${BASE_UNIT}" "/lib/systemd/system/${SVC_TEMPLATE}"
        sed -i '/^WantedBy=/d' "/lib/systemd/system/${SVC_TEMPLATE}"
        log "Создан ${SVC_TEMPLATE}"
    else
        log "Шаблон уже есть, пропускаем."
    fi

    # ── Шаг 2: файл окружения ──
    header "Шаг 2: файл окружения ${ENV_NEW}"
    cp "${ENV_BASE}" "${ENV_NEW}"
    sed -i "s#^PGDATA=.*#PGDATA='${PGDATA_NEW}'#" "${ENV_NEW}"
    log "PGDATA → ${PGDATA_NEW}"

    # ── Шаг 3: override (EnvironmentFile + PGPORT) ──
    header "Шаг 3: override для ${SVC_INSTANCE}"
    mkdir -p "${OVERRIDE_DIR}"
    cat > "${OVERRIDE_DIR}/override.conf" <<EOF
[Unit]
Description=Postgres Pro ${PGVER} database server on port %I

[Service]
EnvironmentFile=/etc/default/postgrespro-${PGVER}-%I
Environment=PGPORT=%I
EOF
    systemctl daemon-reload

    # ── Шаг 4: инициализация кластера ──
    header "Шаг 4: initdb в ${PGDATA_NEW}"
    mkdir -p "${PGDATA_NEW}"
    chown postgres:postgres "${PGDATA_NEW}"
    chmod 700 "${PGDATA_NEW}"
    su - postgres -c "${PG_BIN}/initdb --tune=1c --locale=${PG_LOCALE} --pgdata='${PGDATA_NEW}'"

    # ── Шаг 5: запуск и автозагрузка ──
    header "Шаг 5: запуск и автозагрузка ${SVC_INSTANCE}"
    systemctl start "${SVC_INSTANCE}"
    systemctl enable "${SVC_INSTANCE}"

    local timeout=30 elapsed=0
    until su - postgres -c "${PG_BIN}/pg_isready -p ${PGPORT}" >/dev/null 2>&1; do
        sleep 1; (( elapsed++ )) || true
        (( elapsed < timeout )) || die "Экземпляр не поднялся за ${timeout}с: journalctl -u ${SVC_INSTANCE}"
    done
    log "Экземпляр отвечает на порту ${PGPORT}."

    # ── Шаг 6: пароль ──
    if [[ -n "${INST_PASS}" ]]; then
        header "Шаг 6: пароль суперпользователя"
        su - postgres -c "${PG_BIN}/psql -p ${PGPORT} -c \"ALTER USER postgres WITH PASSWORD '${INST_PASS}';\""
        log "Пароль установлен."
    else
        warn "Пароль не задан. Установите вручную:"
        echo "  su - postgres -c \"${PG_BIN}/psql -p ${PGPORT} -c \\\"ALTER USER postgres WITH PASSWORD 'pass';\\\"\""
    fi

    header "✅ Экземпляр на порту ${PGPORT} создан"
    list_instances "${PGVER}"
}

# ───────────────────────────────────────────────
# КОМАНДА: СПИСОК
# ───────────────────────────────────────────────
cmd_list() {
    require_root
    detect_installed_version
    list_instances "${PGVER}"
}

# ───────────────────────────────────────────────
# МЕНЮ
# ───────────────────────────────────────────────
main_menu() {
    header "═══ Postgres Pro: установка и экземпляры ═══"
    echo "  1) Установить Postgres Pro (выбор версии)"
    echo "  2) Добавить экземпляр (instance)"
    echo "  3) Показать экземпляры"
    echo "  0) Выход"
    local choice
    read -rp "$(echo -e "${CYAN}Действие${RESET} [1]: ")" choice
    case "${choice:-1}" in
        1) cmd_install ;;
        2) cmd_add_instance ;;
        3) cmd_list ;;
        0) exit 0 ;;
        *) die "Неизвестный пункт меню: ${choice}" ;;
    esac
}

# ───────────────────────────────────────────────
# ТОЧКА ВХОДА
# ───────────────────────────────────────────────
case "${1:-menu}" in
    install)             cmd_install ;;
    add-instance|add)    cmd_add_instance ;;
    list|ls)             cmd_list ;;
    menu|"")             require_root; main_menu ;;
    -h|--help|help)
        grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'
        ;;
    *) die "Неизвестная команда: $1 (используйте: install | add-instance | list)" ;;
esac
