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
#   sudo ./pgpro-setup.sh delete-instance ← удалить экземпляр
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
    # confirm "Вопрос" → 0=да, 1=нет. По умолчанию (Enter) — N (нет).
    local prompt="$1"
    while true; do
        read -rp "$(echo -e "${YELLOW}${prompt}${RESET} [y/N]: ")" ans
        case "${ans,,}" in
            y|yes|д|да)        return 0 ;;
            n|no|н|нет|"")     return 1 ;;
            *)                 echo "Введите y или n." ;;
        esac
    done
}

confirm_destroy() {
    # Строгое подтверждение необратимого действия: нужно ввести yes/YES.
    # Любой другой ввод (в т.ч. Enter) — отказ.
    local prompt="$1" ans
    read -rp "$(echo -e "${YELLOW}${prompt}${RESET}\nДля подтверждения введите ${BOLD}yes${RESET} (по умолчанию — НЕТ): ")" ans
    [[ "$ans" == "yes" || "$ans" == "YES" ]]
}

# ───────────────────────────────────────────────
# ПАРАМЕТРЫ ПО УМОЛЧАНИЮ
# ───────────────────────────────────────────────
PGVER="${PGVER:-}"
TIMEZONE="${TIMEZONE:-Asia/Yekaterinburg}"
PG_LOCALE="${PG_LOCALE:-ru_RU.UTF-8}"
POSTGRES_PASS="${POSTGRES_PASS:-}"
PG_PORT="${PG_PORT:-}"          # порт базового кластера (пусто = 5432, спросим если занят)

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

# Реальный порт кластера: сперва PGPORT из файла окружения,
# затем port = из postgresql.auto.conf / postgresql.conf, иначе fallback.
# resolve_port <env_file> <pgdata> <fallback>
resolve_port() {
    local env_file="$1" pgdata="$2" fallback="${3:-5432}" p="" cf
    if [[ -f "$env_file" ]]; then
        p=$(grep -E "^PGPORT=" "$env_file" 2>/dev/null | head -1 | sed "s/^PGPORT=//;s/['\"]//g")
    fi
    if [[ -z "$p" && -n "$pgdata" ]]; then
        for cf in "${pgdata}/postgresql.auto.conf" "${pgdata}/postgresql.conf"; do
            [[ -f "$cf" ]] || continue
            p=$(grep -E "^[[:space:]]*port[[:space:]]*=" "$cf" 2>/dev/null | tail -1 \
                | sed -E "s/^[[:space:]]*port[[:space:]]*=[[:space:]]*([0-9]+).*/\1/")
            [[ -n "$p" ]] && break
        done
    fi
    echo "${p:-$fallback}"
}

# Порт занят? (слушается локально)
port_in_use() {
    ss -tlnH "sport = :${1}" 2>/dev/null | grep -q . \
        || ss -tlnp 2>/dev/null | grep -q ":${1} "
}

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
# Единая таблица по всем установленным версиям Postgres Pro.
list_instances() {
    header "═══ Экземпляры Postgres Pro ═══"

    local vers=()
    mapfile -t vers < <(find /opt/pgpro -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
    if [[ ${#vers[@]} -eq 0 ]]; then
        warn "Установок Postgres Pro не найдено (/opt/pgpro пуст)."
        return
    fi

    printf "${BOLD}%-8s  %-24s  %-6s  %-34s  %-9s${RESET}\n" \
        "ВЕРСИЯ" "СЕРВИС" "ПОРТ" "PGDATA" "СТАТУС"
    printf '%s\n' "$(printf '─%.0s' {1..92})"

    local total=0 ver f base port svc pgdata status
    for ver in "${vers[@]}"; do
        local files=()
        mapfile -t files < <(
            find /etc/default -maxdepth 1 \
                \( -name "postgrespro-${ver}" -o -name "postgrespro-${ver}-*" \) \
                ! -name "*.dpkg*" ! -name "*.bak" 2>/dev/null | sort
        )
        for f in "${files[@]}"; do
            base=$(basename "$f")
            pgdata=$(grep -E "^PGDATA=" "$f" 2>/dev/null | head -1 | sed "s/^PGDATA=//;s/['\"]//g")
            if [[ "$base" == "postgrespro-${ver}" ]]; then
                # Базовый кластер: реальный порт из env/конфига (не всегда 5432).
                port="$(resolve_port "$f" "$pgdata" 5432)"; svc="postgrespro-${ver}"
            else
                port="${base##postgrespro-"${ver}"-}"; svc="postgrespro-${ver}@${port}"
            fi
            if systemctl is-active --quiet "${svc}" 2>/dev/null; then
                status="${GREEN}running${RESET}"
            elif systemctl is-enabled --quiet "${svc}" 2>/dev/null; then
                status="${YELLOW}stopped${RESET}"
            else
                status="${RED}unknown${RESET}"
            fi
            printf "%-8s  %-24s  %-6s  %-34s  %b\n" \
                "${ver}" "${svc}" "${port}" "${pgdata:-—}" "${status}"
            (( total++ )) || true
        done
    done
    printf '%s\n' "$(printf '─%.0s' {1..92})"
    echo -e "Итого: ${BOLD}${total}${RESET} экземпляр(ов)\n"
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
        confirm "Продолжить всё равно?" || { log "Отменено."; return 0; }
    fi

    # Порт базового кластера. По умолчанию 5432; если он занят (например, уже
    # установлена другая версия) — кластер на 5432 не запустится, поэтому
    # запрашиваем свободный порт и прописываем его в postgresql.conf.
    local INSTALL_PORT="${PG_PORT:-5432}"
    if port_in_use "${INSTALL_PORT}"; then
        warn "Порт ${INSTALL_PORT} уже занят (вероятно, другим кластером Postgres Pro)."
        if [[ -t 0 ]]; then
            while true; do
                read -rp "$(echo -e "${CYAN}Порт для нового кластера${RESET} [5433]: ")" INSTALL_PORT
                INSTALL_PORT="${INSTALL_PORT:-5433}"
                [[ "$INSTALL_PORT" =~ ^[0-9]{4,5}$ ]] || { warn "Некорректный порт."; continue; }
                port_in_use "${INSTALL_PORT}" && { warn "Порт ${INSTALL_PORT} занят."; continue; }
                break
            done
        else
            die "Порт ${INSTALL_PORT} занят. Укажите свободный: PG_PORT=NNNN."
        fi
    fi
    log "Порт кластера: ${INSTALL_PORT}"

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

    # Если порт не 5432 — прописываем его в postgresql.conf до старта.
    if [[ "${INSTALL_PORT}" != "5432" ]]; then
        log "Установка порта ${INSTALL_PORT} в postgresql.conf"
        local conf="${PG_DATA}/postgresql.conf"
        if grep -qE '^[[:space:]]*#?[[:space:]]*port[[:space:]]*=' "${conf}"; then
            sed -ri "0,/^[[:space:]]*#?[[:space:]]*port[[:space:]]*=.*/s//port = ${INSTALL_PORT}/" "${conf}"
        else
            echo "port = ${INSTALL_PORT}" >> "${conf}"
        fi
    fi

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

    # Ожидание готовности кластера на выбранном порту
    local timeout=30 elapsed=0
    until su - postgres -c "${PG_BIN}/pg_isready -p ${INSTALL_PORT}" >/dev/null 2>&1; do
        sleep 1; (( elapsed++ )) || true
        (( elapsed < timeout )) || die "Кластер не поднялся за ${timeout}с: journalctl -u ${PG_SERVICE}"
    done

    # Пароль суперпользователя
    if [[ -z "${POSTGRES_PASS}" ]]; then
        POSTGRES_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20 || true)"
        log "Сгенерирован пароль пользователя postgres."
    fi
    su - postgres -c "${PG_BIN}/psql -p ${INSTALL_PORT} -v ON_ERROR_STOP=1 -c \"ALTER USER postgres WITH PASSWORD '${POSTGRES_PASS}';\""

    # pg_hba: метод scram-sha-256 (как в статье)
    local PG_HBA="${PG_DATA}/pg_hba.conf"
    if [[ -f "${PG_HBA}" ]]; then
        log "Настройка pg_hba.conf (scram-sha-256)"
        sed -ri 's/^(local\s+all\s+all\s+)(peer|trust|md5|ident)\b/\1scram-sha-256/' "${PG_HBA}"
        sed -ri 's/^(host\s+all\s+all\s+127\.0\.0\.1\/32\s+)(trust|md5|ident)\b/\1scram-sha-256/' "${PG_HBA}"
        su - postgres -c "${PG_BIN}/psql -p ${INSTALL_PORT} -c 'SELECT pg_reload_conf();'" >/dev/null
    fi

    # .pgpass для текущего (вызвавшего) пользователя
    local exec_home pgpass
    exec_home="$(getent passwd "$(id -u)" | cut -d: -f6)"
    if [[ -n "${exec_home}" && -d "${exec_home}" ]]; then
        pgpass="${exec_home}/.pgpass"
        log "Создание ${pgpass}"
        cat > "${pgpass}" <<EOF
#hostname:port:database:username:password
localhost:${INSTALL_PORT}:postgres:postgres:${POSTGRES_PASS}
EOF
        chmod 600 "${pgpass}"
        chown "$(id -u):$(id -g)" "${pgpass}" || true
    fi

    [[ "${DO_IPV6}" -eq 1 ]] && disable_ipv6

    local psql_hint="${PG_BIN}/psql"
    [[ "${INSTALL_PORT}" != "5432" ]] && psql_hint="${PG_BIN}/psql -p ${INSTALL_PORT}"

    header "✅ Установка Postgres Pro ${PGVER} завершена"
    printf "  ${BOLD}%-16s${RESET} %s\n" "Версия:"  "${PGVER}"
    printf "  ${BOLD}%-16s${RESET} %s\n" "Служба:"  "${PG_SERVICE}"
    printf "  ${BOLD}%-16s${RESET} %s\n" "Порт:"    "${INSTALL_PORT}"
    printf "  ${BOLD}%-16s${RESET} %s\n" "PGDATA:"  "${PG_DATA}"
    printf "  ${BOLD}%-16s${RESET} %s\n" "Локаль:"  "${PG_LOCALE}"
    printf "  ${BOLD}%-16s${RESET} %s\n" "Пароль postgres:" "${POSTGRES_PASS}"
    echo ""
    echo "Проверка: systemctl status ${PG_SERVICE}"
    echo "Подключение: su - postgres -c \"${psql_hint}\""
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

    list_instances

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
    confirm "Создать экземпляр?" || { log "Отменено."; return 0; }

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
    list_instances
}

# ───────────────────────────────────────────────
# КОМАНДА: СПИСОК
# ───────────────────────────────────────────────
cmd_list() {
    require_root
    list_instances
}

# ───────────────────────────────────────────────
# КОМАНДА: УДАЛИТЬ ЭКЗЕМПЛЯР
# ───────────────────────────────────────────────
cmd_delete_instance() {
    require_root

    # Собираем все дополнительные экземпляры (с портом) по всем версиям
    local vers=() entries=() ver f base port
    mapfile -t vers < <(find /opt/pgpro -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
    for ver in "${vers[@]}"; do
        local files=()
        mapfile -t files < <(
            find /etc/default -maxdepth 1 -name "postgrespro-${ver}-*" \
                ! -name "*.dpkg*" ! -name "*.bak" 2>/dev/null | sort
        )
        for f in "${files[@]}"; do
            base=$(basename "$f")
            port="${base##postgrespro-"${ver}"-}"
            [[ "$port" =~ ^[0-9]{4,5}$ ]] || continue
            entries+=("${ver}|${port}")
        done
    done

    list_instances

    if [[ ${#entries[@]} -eq 0 ]]; then
        warn "Дополнительных экземпляров нет. Базовый кластер (порт 5432) удаляется через apt."
        return
    fi

    header "Выберите экземпляр для удаления:"
    local i=1 e
    for e in "${entries[@]}"; do
        printf "  ${BOLD}%2d${RESET}) postgrespro-%s@%s\n" "$i" "${e%%|*}" "${e##*|}"
        (( i++ )) || true
    done
    printf "  ${BOLD}%2d${RESET}) отмена\n" "$i"

    local choice
    read -rp "$(echo -e "${CYAN}Экземпляр${RESET}: ")" choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#entries[@]} )); then
        log "Отменено."; return
    fi

    local sel="${entries[choice-1]}"
    local del_ver="${sel%%|*}"
    local PGPORT="${sel##*|}"
    local SVC="postgrespro-${del_ver}@${PGPORT}"
    local ENV_FILE="/etc/default/postgrespro-${del_ver}-${PGPORT}"
    local OVERRIDE_DIR="/etc/systemd/system/${SVC}.service.d"
    local PGDATA
    PGDATA=$(grep -E "^PGDATA=" "$ENV_FILE" 2>/dev/null | head -1 | sed "s/^PGDATA=//;s/['\"]//g")

    echo ""
    warn "Будет удалён экземпляр ${SVC} (порт ${PGPORT})."
    printf "  PGDATA: %s\n" "${PGDATA:-—}"
    confirm "Остановить экземпляр и удалить его конфигурацию?" || { log "Отменено."; return; }

    log "Остановка и отключение ${SVC}"
    systemctl stop "${SVC}" 2>/dev/null || true
    systemctl disable "${SVC}" 2>/dev/null || true

    log "Удаление override и файла окружения"
    rm -rf "${OVERRIDE_DIR}"
    rm -f "${ENV_FILE}"
    systemctl daemon-reload
    systemctl reset-failed "${SVC}" 2>/dev/null || true

    if [[ -n "${PGDATA}" && -d "${PGDATA}" ]]; then
        if confirm_destroy "Удалить каталог данных ${PGDATA}? Это НЕОБРАТИМО."; then
            rm -rf "${PGDATA}"
            log "Каталог данных удалён: ${PGDATA}"
        else
            warn "Каталог данных оставлен: ${PGDATA}"
        fi
    fi

    header "✅ Экземпляр ${SVC} удалён"
    list_instances
}

# ───────────────────────────────────────────────
# МЕНЮ
# ───────────────────────────────────────────────
# Показ экземпляров с возвратом в меню или выходом (скрипт сам не закрывается).
menu_list() {
    list_instances
    echo "  1) Назад в меню"
    echo "  0) Выход"
    local c
    read -rp "$(echo -e "${CYAN}Действие${RESET} [1]: ")" c
    case "${c:-1}" in
        0) exit 0 ;;
        *) return 0 ;;
    esac
}

main_menu() {
    while true; do
        header "═══ Postgres Pro: установка и экземпляры ═══"
        echo "  1) Установить Postgres Pro (выбор версии)"
        echo "  2) Добавить экземпляр (instance)"
        echo "  3) Показать экземпляры"
        echo "  4) Удалить экземпляр (instance)"
        echo "  0) Выход"
        local choice
        read -rp "$(echo -e "${CYAN}Действие${RESET} [1]: ")" choice
        case "${choice:-1}" in
            1) cmd_install ;;
            2) cmd_add_instance ;;
            3) menu_list ;;
            4) cmd_delete_instance ;;
            0) exit 0 ;;
            *) warn "Неизвестный пункт меню: ${choice}" ;;
        esac
    done
}

# ───────────────────────────────────────────────
# ТОЧКА ВХОДА
# ───────────────────────────────────────────────
case "${1:-menu}" in
    install)                   cmd_install ;;
    add-instance|add)          cmd_add_instance ;;
    delete-instance|del|rm)    cmd_delete_instance ;;
    list|ls)                   cmd_list ;;
    menu|"")                   require_root; main_menu ;;
    -h|--help|help)
        grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'
        ;;
    *) die "Неизвестная команда: $1 (используйте: install | add-instance | list)" ;;
esac
