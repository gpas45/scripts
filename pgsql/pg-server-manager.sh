#!/bin/bash
#
# pg-server-manager.sh — интерактивный менеджер Postgres Pro 1C для Linux (Debian/Ubuntu)
#
# Аналог 1c-server-manager.sh, но для СУБД Postgres Pro (линейка 1C):
#   • Базовая настройка сервера (ОС): локали, часовой пояс, консоль, базовые пакеты
#   • Установка / удаление РАЗНЫХ релизов (1c-16/1c-17/1c-18 …), параллельно в /opt/pgpro/<ver>
#   • Управление НЕСКОЛЬКИМИ экземплярами (кластерами): создать/удалить/старт/стоп/статус
#   • Настройка экземпляра: порт, пароль postgres, внешний доступ (listen_addresses + pg_hba)
#   • whiptail/dialog TUI с откатом в консольный режим, логирование в pg-server-manager.log
#
# Несколько экземпляров реализованы вручную (pg-setup умеет только один кластер):
# отдельный каталог данных + копия штатного systemd-юнита + drop-in PGDATA + свой порт.
#
set -o pipefail

# ── Локаль: по умолчанию ru_RU.UTF-8; применяется, если текущая отличается ──
PREFERRED_LOCALE="ru_RU.UTF-8"
if [[ "${LANG:-}" != "$PREFERRED_LOCALE" ]]; then
    if locale -a 2>/dev/null | grep -qiE '^ru_RU\.utf-?8$'; then
        export LANG="$PREFERRED_LOCALE" LC_ALL="$PREFERRED_LOCALE" LANGUAGE="ru_RU:ru"
    elif locale -a 2>/dev/null | grep -qiE '^C\.utf-?8$'; then
        export LANG=C.UTF-8 LC_ALL=C.UTF-8
    elif locale -a 2>/dev/null | grep -qiE 'utf-?8'; then
        l=$(locale -a 2>/dev/null | grep -iE 'utf-?8' | head -n1)
        export LANG="$l" LC_ALL="$l"
    fi
fi

# ───────────────────────────── Константы ─────────────────────────────
PGPRO_BASE="/opt/pgpro"
DATA_BASE="/var/lib/pgpro"
SYSTEMD_DIR="/etc/systemd/system"
LOG_FILE="pg-server-manager.log"
REPO_BASE="https://repo.postgrespro.ru"
# Часто используемые релизы для меню (можно ввести вручную любой 1c-N)
KNOWN_VERSIONS=(1c-18 1c-17 1c-16)
# Часовой пояс/локаль по умолчанию для базовой настройки ОС
TZ_DEFAULT="Asia/Yekaterinburg"
DEF_LOCALE="ru_RU.UTF-8"
LOG_LOCALE="en_US.UTF-8"   # lc_messages кластеров — журналы сервера на английском

# Цвета консольного режима (используются только BLUE и NC)
BLUE='\033[0;34m'; NC='\033[0m'

# Подпись кнопки отмены: на главном меню — «Выход», в подменю — «Назад»
CANCEL_LABEL="Назад"

# Проверка root
if [[ $EUID -ne 0 ]]; then
    echo "Запустите скрипт от имени root"; exit 1
fi

# Поддержка только Debian/Ubuntu
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if ! echo "${ID_LIKE:-${ID:-}}" | tr '[:upper:]' '[:lower:]' | grep -Eq 'debian|ubuntu'; then
        echo "Скрипт поддерживает только Debian/Ubuntu"; exit 1
    fi
fi

export DEBIAN_FRONTEND=noninteractive

# Способ запуска команд от пользователя postgres.
# sudo на минимальном Debian часто отсутствует (скрипт и так идёт от root),
# поэтому по умолчанию используем runuser из util-linux, который есть всегда.
if command -v runuser >/dev/null 2>&1; then
    RUN_AS_PG="runuser -u postgres --"
elif command -v sudo >/dev/null 2>&1; then
    RUN_AS_PG="sudo -u postgres --"
else
    echo "Не найдены ни runuser, ни sudo — невозможно выполнять команды от пользователя postgres"; exit 1
fi

# Инструмент TUI (whiptail или dialog), если установлен
DIALOG=$(command -v whiptail || command -v dialog || true)

# Рабочий каталог = каталог скрипта
cd "$(dirname "$0")" || exit 1

# ───────────────────────── UI-слой (TUI/консоль) ────────────────────
# whiptail рисует интерфейс в stdout; функции часто вызываются внутри $(...),
# поэтому UI принудительно направляем в терминал (stderr/ /dev/tty).

ui_msg() { # ui_msg "текст"
    if [[ -n "$DIALOG" ]]; then "$DIALOG" --msgbox "$1" 16 78 1>&2; else echo -e "$1" >&2; fi
}

ui_yesno() { # ui_yesno "вопрос" -> 0 (да) / 1 (нет)
    if [[ -n "$DIALOG" ]]; then
        "$DIALOG" --yesno "$1" 12 78 1>&2
    else
        local a; read -rp "$1 (y/N): " a </dev/tty 2>/dev/tty; [[ $a =~ ^[YyДд] ]]
    fi
}

ui_input() { # ui_input "запрос" "значение_по_умолчанию" -> echo результата
    local prompt=$1 def=$2 res
    if [[ -n "$DIALOG" ]]; then
        res=$("$DIALOG" --inputbox "$prompt" 10 78 "$def" 3>&1 1>&2 2>&3) || return 1
    else
        read -rp "$prompt [${def}]: " res </dev/tty 2>/dev/tty; res=${res:-$def}
    fi
    echo "$res"
}

ui_password() { # ui_password "запрос" -> echo введённого пароля (или пусто = отмена/сгенерировать)
    local prompt=$1 res
    if [[ -n "$DIALOG" ]]; then
        res=$("$DIALOG" --passwordbox "$prompt" 10 78 3>&1 1>&2 2>&3) || return 1
    else
        read -rsp "$prompt: " res </dev/tty 2>/dev/tty; echo >&2
    fi
    echo "$res"
}

# Подтверждение деструктивного действия точным ручным вводом.
# ui_confirm_text "пояснение" "слово" -> 0, только если введено ровно «слово».
# В строке запроса ВСЕГДА явно указано, что именно набрать.
ui_confirm_text() {
    local text=$1 token=$2 res
    if [[ -n "$DIALOG" ]]; then
        res=$("$DIALOG" --inputbox "${text}\n\nДля подтверждения введите слово: ${token}\n(оставьте пустым или нажмите Отмена, чтобы НЕ выполнять)" 18 78 "" 3>&1 1>&2 2>&3) || return 1
    else
        echo -e "$text" >&2
        read -rp "Для подтверждения введите слово «${token}» (пусто — отмена): " res </dev/tty 2>/dev/tty
    fi
    [[ "$res" == "$token" ]]
}

# ui_menu "заголовок" "подпись" tag1 "название1" ... -> echo выбранного tag
ui_menu() {
    local title=$1 text=$2; shift 2
    local tags=() descs=()
    while (( $# )); do tags+=("$1"); descs+=("${2:-}"); shift 2; done
    local n=${#tags[@]} i
    (( n == 0 )) && return 1
    if [[ -n "$DIALOG" ]]; then
        local margs=()
        for i in "${!tags[@]}"; do margs+=( "$((i+1))" "${descs[$i]}" ); done
        local h=$(( n + 8 )); (( h > 22 )) && h=22
        local sel
        sel=$("$DIALOG" --clear --title " $title " \
              --ok-button "Выбрать" --cancel-button "${CANCEL_LABEL:-Назад}" \
              --menu "\n$text" "$h" 76 "$n" "${margs[@]}" 3>&1 1>&2 2>&3) || return 1
        [[ $sel =~ ^[0-9]+$ ]] || return 1
        echo "${tags[$((sel-1))]}"
    else
        echo -e "\n${BLUE}=== $title ===${NC}\n$text" >&2
        for i in "${!tags[@]}"; do echo -e "  $((i+1))) ${descs[$i]}" >&2; done
        echo -e "  0) ${CANCEL_LABEL:-Назад}" >&2
        local sel; read -rp "Выбор: " sel </dev/tty 2>/dev/tty
        [[ "$sel" == 0 ]] && return 1
        if [[ $sel =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= n )); then
            echo "${tags[$((sel-1))]}"
        else
            return 1
        fi
    fi
}

# Запуск команды с показом реального вывода + лог.
run_cmd() { # run_cmd "команда" "описание"
    local command=$1 desc=$2 rc tmp="/tmp/pg_run_$$.out"
    echo "=== $(date '+%F %T') :: $desc" >> "$LOG_FILE"
    echo "CMD: $command" >> "$LOG_FILE"
    echo  >&2
    echo "──────────────────────────────────────────────────────────" >&2
    echo ">>> $desc" >&2
    echo "──────────────────────────────────────────────────────────" >&2
    eval "$command" 2>&1 | tee -a "$tmp" >&2
    rc=${PIPESTATUS[0]}
    cat "$tmp" >> "$LOG_FILE" 2>/dev/null
    if [[ $rc -ne 0 ]]; then
        echo -e "\n!!! ОШИБКА: $desc (код $rc)" >&2
        ui_msg "Ошибка: $desc (код $rc)\n\n$(tail -15 "$tmp" 2>/dev/null)"
    fi
    rm -f "$tmp"
    return "$rc"
}

# ───────────────────────────── Утилиты ──────────────────────────────
# Корректный формат релиза линейки 1С: 1c-<major>
is_valid_pgver() { [[ $1 =~ ^1c-[0-9]+$ ]]; }
# Мажорная версия (число) из релиза: 1c-18 -> 18
pgmajor() { [[ $1 =~ ^1c-([0-9]+)$ ]] && echo "${BASH_REMATCH[1]}"; }

# Путь к bin установленного релиза
pg_bin() { echo "$PGPRO_BASE/$1/bin"; }

# Проверка свободного места: $1 — путь, $2 — требуется ГБ
check_free_space() {
    local path=$1 need_gb=$2 avail_kb
    avail_kb=$(df -Pk "$path" 2>/dev/null | awk 'NR==2{print $4}')
    [[ -z "$avail_kb" ]] && { ui_msg "Не удалось определить свободное место на $path"; return 1; }
    if (( avail_kb < need_gb * 1024 * 1024 )); then
        ui_msg "Недостаточно места на $path: доступно $((avail_kb/1024/1024))ГБ, требуется >= ${need_gb}ГБ"
        return 1
    fi
    return 0
}

# Проверка наличия одной локали в системе (locale -a печатает ru_RU.utf8 без дефиса)
locale_present() {
    local base=${1%.UTF-8}
    locale -a 2>/dev/null | grep -qiE "^${base}\.utf-?8$"
}

# Гарантируем обязательные локали: ru_RU.UTF-8 (для initdb кластера под 1С) и
# en_US.UTF-8 (для lc_messages — журналы сервера на английском).
# Возвращает 0, если обе есть/сгенерированы; 1 — иначе.
ensure_locales() {
    local need=("$DEF_LOCALE" "$LOG_LOCALE") missing=() L
    for L in "${need[@]}"; do locale_present "$L" || missing+=("$L"); done
    (( ${#missing[@]} == 0 )) && return 0
    ui_yesno "Не найдены обязательные локали: ${missing[*]}\n($DEF_LOCALE — для кластера, $LOG_LOCALE — для lc_messages журналов).\nСгенерировать их сейчас?" || {
        ui_msg "Прервано: без локалей ${missing[*]} кластер не будет работать корректно.\nВыполните «Базовая настройка сервера (ОС)» и повторите."
        return 1
    }
    run_cmd "apt-get install -y locales" "Установка пакета locales"
    sed -i 's/^# *\(ru_RU.UTF-8 UTF-8\)/\1/; s/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen 2>/dev/null
    grep -qxF "ru_RU.UTF-8 UTF-8" /etc/locale.gen 2>/dev/null || echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen
    grep -qxF "en_US.UTF-8 UTF-8" /etc/locale.gen 2>/dev/null || echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
    run_cmd "locale-gen" "Генерация локалей $DEF_LOCALE и $LOG_LOCALE"
    for L in "${need[@]}"; do
        locale_present "$L" || { ui_msg "Не удалось сгенерировать $L. Проверьте пакет locales и /etc/locale.gen."; return 1; }
    done
    return 0
}

# Установленные релизы (есть bin/postgres)
discover_installed_versions() {
    [[ -d "$PGPRO_BASE" ]] || return 0
    find "$PGPRO_BASE" -maxdepth 1 -mindepth 1 -type d -printf "%f\n" 2>/dev/null | while read -r v; do
        [[ $v =~ ^1c-[0-9]+$ && -x "$PGPRO_BASE/$v/bin/postgres" ]] && echo "$v"
    done | sort -rV
}

# Репозиторий Postgres Pro для релиза уже добавлен?
# Файлы вида /etc/apt/sources.list.d/postgresql-1c-18.list (или postgrespro-1c-18.list)
repo_present() {
    local major f
    major=$(pgmajor "$1")
    [[ -z "$major" ]] && return 1
    for f in /etc/apt/sources.list.d/*1c-"$major"*.list /etc/apt/sources.list.d/*1c_"$major"*.list; do
        [[ -e "$f" ]] && return 0
    done
    return 1
}

# Штатный systemd-юнит релиза (ищем фактический путь, не хардкодим)
stock_unit_path() {
    local ver=$1 p
    for p in "/lib/systemd/system/postgrespro-$ver.service" \
             "/usr/lib/systemd/system/postgrespro-$ver.service" \
             "/etc/systemd/system/postgrespro-$ver.service"; do
        [[ -f "$p" ]] && { echo "$p"; return 0; }
    done
    return 1
}

# Все экземпляры релиза: дефолтный (postgrespro-<ver>) + кастомные (postgrespro-<ver>-*)
# Возвращает имена юнитов (без .service).
discover_instances() {
    local ver=$1
    {
        [[ -n "$(stock_unit_path "$ver")" ]] && echo "postgrespro-$ver"
        local f
        for f in "$SYSTEMD_DIR"/postgrespro-"$ver"-*.service; do
            [[ -f "$f" ]] || continue
            basename "$f" .service
        done
    } | sort -u
}

# Все экземпляры всех установленных релизов
discover_all_instances() {
    local v
    while read -r v; do
        [[ -z "$v" ]] && continue
        discover_instances "$v"
    done < <(discover_installed_versions)
}

# Имя экземпляра по юниту: postgrespro-1c-18 -> default; postgrespro-1c-18-buh -> buh
instance_name() {
    local u=$1 ver=$2
    if [[ "$u" == "postgrespro-$ver" ]]; then echo "default"; else echo "${u#postgrespro-$ver-}"; fi
}

# Релиз по имени юнита: postgrespro-1c-18[-name] -> 1c-18
instance_ver() {
    [[ $1 =~ ^postgrespro-(1c-[0-9]+) ]] && echo "${BASH_REMATCH[1]}"
}

# Реальный PGDATA экземпляра из systemd (drop-in override / EnvironmentFile).
# Пусто, если не задан (юнит не существует или путь не прописан).
unit_pgdata() {
    systemctl show "$1" -p Environment --no-pager 2>/dev/null \
        | tr ' ' '\n' | sed -n 's/^PGDATA=//p' | head -n1
}

# Каталог данных экземпляра.
#   default -> <DATA_BASE>/<ver>/data
#   кастом  -> реальный PGDATA из systemd, если юнит уже есть (устойчиво к старой
#              схеме <DATA_BASE>/<ver>/<порт>); иначе вычисляемый <DATA_BASE>/<ver>/data-<name>
#              (имя = порт), который используется при СОЗДАНИИ нового экземпляра.
instance_datadir() {
    local ver=$1 name=$2 pgdata
    if [[ "$name" == "default" ]]; then echo "$DATA_BASE/$ver/data"; return; fi
    pgdata=$(unit_pgdata "postgrespro-$ver-$name")
    echo "${pgdata:-$DATA_BASE/$ver/data-$name}"
}

# Порт экземпляра: из postgresql.conf каталога данных (по умолчанию 5432)
instance_port() {
    local datadir=$1 p=""
    [[ -f "$datadir/postgresql.conf" ]] && \
        p=$(grep -E '^[[:space:]]*port[[:space:]]*=' "$datadir/postgresql.conf" 2>/dev/null \
            | tail -n1 | grep -oE '[0-9]+' | head -n1)
    echo "${p:-5432}"
}

# Порт занят: либо слушается, либо уже назначен какому-то экземпляру (любого релиза)
port_taken() {
    local port=$1 f
    ss -tulpn 2>/dev/null | grep -qE ":${port}\b" && return 0
    for f in "$SYSTEMD_DIR"/postgrespro-*-"$port".service; do
        [[ -e "$f" ]] && return 0
    done
    return 1
}

# Подсказка следующего свободного порта (5432 — дефолтный кластер, новые с 5433)
suggest_port() {
    local port=5433
    while port_taken "$port"; do ((port++)); done
    echo "$port"
}

# Информативная подпись экземпляра для меню
instance_desc() {
    local u=$1 ver name datadir port st
    ver=$(instance_ver "$u"); name=$(instance_name "$u" "$ver")
    datadir=$(instance_datadir "$ver" "$name")
    port=$(instance_port "$datadir")
    st=$(systemctl is-active "$u" 2>/dev/null || echo "?")
    echo "$name · $ver · порт $port · $st"
}

# Выбор установленного релиза через UI; echo -> версия, return 1 при отмене/отсутствии
pick_installed_version() {
    local title=${1:-"Выбор релиза"}
    mapfile -t vers < <(discover_installed_versions)
    (( ${#vers[@]} == 0 )) && { ui_msg "Установленные релизы Postgres Pro не найдены"; return 1; }
    local args=() v
    for v in "${vers[@]}"; do args+=("$v" "релиз $v"); done
    ui_menu "$title" "Выберите релиз Postgres Pro" "${args[@]}"
}

# Выбор экземпляра (по всем релизам) через UI; echo -> имя юнита, return 1 при отмене
pick_instance() {
    local title=${1:-"Выбор экземпляра"}
    mapfile -t inst < <(discover_all_instances)
    (( ${#inst[@]} == 0 )) && { ui_msg "Экземпляров не найдено. Сначала установите релиз."; return 1; }
    local args=() u
    for u in "${inst[@]}"; do args+=("$u" "$(instance_desc "$u")"); done
    ui_menu "$title" "Выберите экземпляр (кластер)" "${args[@]}"
}

# ─────────────────── 1С-тюнинг каталога данных (для кастомных экземпляров) ───────
# Дефолтный кластер тюнингуется штатным `pg-setup initdb --tune=1c`. Для
# дополнительных экземпляров применяем эквивалентный набор параметров отдельным
# include-файлом, чтобы не перетирать пользовательские правки postgresql.conf.
apply_1c_tuning() {
    local datadir=$1
    local confd="$datadir/conf.d"
    mkdir -p "$confd"
    cat > "$confd/1c.conf" <<'EOF'
# Рекомендованные параметры для работы с 1С:Предприятие (аналог pg-setup --tune=1c)
max_connections = 1000
standard_conforming_strings = off
escape_string_warning = off
shared_preload_libraries = 'online_analyze, plantuner'
plantuner.fix_empty_table = on
online_analyze.enable = on
online_analyze.table_type = 'temporary'
online_analyze.verbose = off
online_analyze.local_tracking = on
online_analyze.min_interval = 10000
online_analyze.min_gain = 10
EOF
    # Гарантируем подключение каталога conf.d из основного конфига
    grep -qE "include_dir[[:space:]]*=[[:space:]]*'conf\.d'" "$datadir/postgresql.conf" 2>/dev/null \
        || echo "include_dir = 'conf.d'" >> "$datadir/postgresql.conf"
}

# ─────────────── Журналирование кластера (log/ + lc_messages=en_US) ──────────────
# Дописываем параметры журналирования в конец postgresql.conf (PostgreSQL берёт
# последнее значение): файлы в каталог log/, сообщения сервера на английском.
apply_log_config() {
    local conf="$1/postgresql.conf"
    grep -q "lc_messages = '$LOG_LOCALE'" "$conf" 2>/dev/null && return 0
    cat >> "$conf" <<EOF

# Журналы: сбор в файлы, каталог log/, сообщения на английском
logging_collector = on
log_directory = 'log'
lc_messages = '$LOG_LOCALE'
EOF
}

# Контрольные суммы страниц (нужны для 1С). pg_checksums --enable работает только
# на ОСТАНОВЛЕННОМ кластере, поэтому при необходимости останавливаем службу.
# Если суммы уже включены (PG 17/18 включают их при initdb) — просто выходим.
enable_checksums() {
    local ver=$1 datadir=$2 unit=$3 bin
    bin=$(pg_bin "$ver")
    [[ -x "$bin/pg_checksums" ]] || return 0
    "$bin/pg_controldata" "$datadir" 2>/dev/null | grep -qE 'Data page checksum version:[[:space:]]*[1-9]' && return 0
    [[ -n "$unit" ]] && systemctl is-active --quiet "$unit" \
        && run_cmd "systemctl stop $unit" "Остановка $unit (для включения контрольных сумм)"
    run_cmd "$RUN_AS_PG '$bin/pg_checksums' --enable -D '$datadir'" "Включение контрольных сумм страниц ($ver)"
}

# ───────────────── Базовая настройка сервера (ОС) ───────────────────
base_setup_os() {
    ui_yesno "Выполнить базовую настройку ОС?\n\n• apt update/upgrade\n• пакеты: mc nano console-setup net-tools htop curl ca-certificates gnupg lsb-release locales sudo tzdata\n• локали ru_RU.UTF-8 + en_US.UTF-8\n• часовой пояс $TZ_DEFAULT\n• console-setup (UTF-8, TerminusBold 8x16)" || return

    run_cmd "apt-get update -y" "Обновление индексов пакетов"
    run_cmd "apt-get -o Dpkg::Options::=--force-confnew dist-upgrade -y" "Обновление системы (dist-upgrade)"
    run_cmd "apt-get install -y mc nano console-setup net-tools htop curl ca-certificates gnupg lsb-release locales sudo tzdata" "Установка базовых пакетов"

    # Локали — идемпотентно
    sed -i 's/^# *\(ru_RU.UTF-8 UTF-8\)/\1/; s/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen 2>/dev/null
    grep -qxF "ru_RU.UTF-8 UTF-8" /etc/locale.gen 2>/dev/null || echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen
    grep -qxF "en_US.UTF-8 UTF-8" /etc/locale.gen 2>/dev/null || echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
    run_cmd "locale-gen" "Генерация локалей"
    run_cmd "update-locale LANG=$DEF_LOCALE LC_ALL=$DEF_LOCALE" "Локаль по умолчанию $DEF_LOCALE"
    export LANG="$DEF_LOCALE" LC_ALL="$DEF_LOCALE" LANGUAGE="ru_RU:ru"

    # Часовой пояс (с запасным путём для LXC без timedated)
    if command -v timedatectl >/dev/null 2>&1 && timedatectl set-timezone "$TZ_DEFAULT" 2>/dev/null; then
        :
    else
        ln -sf "/usr/share/zoneinfo/$TZ_DEFAULT" /etc/localtime
        echo "$TZ_DEFAULT" > /etc/timezone
        dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1 || true
    fi

    # Консоль — без диалогов
    cat > /etc/default/console-setup <<'EOF'
ACTIVE_CONSOLES="/dev/tty[1-6]"
CHARMAP="UTF-8"
CODESET="guess"
FONTFACE="TerminusBold"
FONTSIZE="8x16"
EOF
    setupcon --force >/dev/null 2>&1 || true

    ui_msg "Базовая настройка завершена.\n\nДата/время: $(date '+%F %T %Z')\nЛокаль по умолчанию: $DEF_LOCALE\n\nОтключение IPv6 — в отдельном пункте меню «IPv6»."
}

# ──────────────────────────── Меню: IPv6 ────────────────────────────
IPV6_FILE="/etc/sysctl.d/99-disable-ipv6.conf"

ipv6_status() {
    [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" == "1" ]] && echo "отключён" || echo "включён"
}

ipv6_disable() {
    cat > "$IPV6_FILE" <<'EOF'
# Отключение IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    # Применяем ТОЛЬКО наш файл: sysctl --system в LXC падает на чужих ключах.
    echo "=== $(date '+%F %T') :: Отключение IPv6" >> "$LOG_FILE"
    if sysctl -p "$IPV6_FILE" >>"$LOG_FILE" 2>&1; then
        ui_msg "IPv6 отключён.\nФайл: $IPV6_FILE"
    else
        ui_msg "IPv6 прописан в $IPV6_FILE, но применить sysctl не удалось\n(в LXC применение может быть ограничено хостом). Применится после перезагрузки."
    fi
}

ipv6_enable() {
    rm -f "$IPV6_FILE"
    echo "=== $(date '+%F %T') :: Включение IPv6" >> "$LOG_FILE"
    sysctl -w net.ipv6.conf.all.disable_ipv6=0     >>"$LOG_FILE" 2>&1 || true
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >>"$LOG_FILE" 2>&1 || true
    sysctl -w net.ipv6.conf.lo.disable_ipv6=0      >>"$LOG_FILE" 2>&1 || true
    ui_msg "IPv6 включён (файл отключения удалён)."
}

menu_ipv6() {
    while true; do
        local c; c=$(ui_menu "IPv6 (сейчас: $(ipv6_status))" "Управление IPv6" \
            disable "Отключить IPv6" \
            enable  "Включить IPv6") || return
        case $c in
            disable) ipv6_disable ;;
            enable)  ipv6_enable ;;
        esac
    done
}

# ──────────────────────────── Меню: MOTD ────────────────────────────
# Динамический баннер Debian при входе по SSH (/etc/update-motd.d).
MOTD_FILE="/etc/update-motd.d/99-pgpro-info"

motd_install() {
    local org; org=$(ui_input "Название организации для баннера" "Организация") || return
    {
        echo "#!/bin/bash"
        printf 'ORG=%q\n' "$org"     # безопасная подстановка названия организации
        cat <<'MOTD_EOF'
# MOTD-баннер сервера Postgres Pro (установлен pg-server-manager.sh)
tcLtG=$'\033[00;37m'; tcDkG=$'\033[01;30m'; tcW=$'\033[01;37m'
tcRESET=$'\033[0m'; tcORANGE=$'\033[38;5;209m'
HOUR=$(date +"%H")
if   [ "$HOUR" -lt 12 ]; then TIME="morning"
elif [ "$HOUR" -lt 17 ]; then TIME="afternoon"
else TIME="evening"; fi
up=$(cut -f1 -d. /proc/uptime)
upDays=$((up/60/60/24)); upHours=$((up/60/60%24)); upMins=$((up/60%60))
MEMpct=$(free -m | awk '/Mem/ {printf("%3.1f%%", $3/$2*100)}')
MEMu=$(free -t -m | awk '/Mem/ {print $3" MB"}')
MEMt=$(free -t -m | awk '/Mem/ {print $2" MB"}')
ROOTu=$(df -h / | awk 'NR==2 {print $(NF-1)}')
LOADS=$(awk '{print $1}' /proc/loadavg)
SWAPu=$(free -m | awk '/Swap/ {print $3}')
PROCS=$(ps ax | wc -l)
IPADDR=$(hostname -I | awk '{print $1}')

get_pg_clusters() {
    local active
    active=$(systemctl list-units -t service --state=active --no-legend --no-pager 2>/dev/null \
             | awk '{print $1}' | grep -E '^postgrespro-' | sort -u)
    if [ -z "$active" ]; then
        echo -e "${tcLtG} - Кластеры PG.........:${tcW} активных кластеров не найдено"
        return
    fi
    echo "$active" | while read -r u; do
        u=${u%.service}
        ver=$(echo "$u" | grep -oE '1c-[0-9]+'); ver=${ver:-?}
        port=$(systemctl show "$u" -p Environment --no-pager 2>/dev/null | grep -oE 'PGPORT=[0-9]+' | cut -d= -f2)
        echo -e "${tcLtG} - Кластер.............:${tcW} $u (релиз $ver, порт ${port:-5432})"
    done
}

echo -e "${tcDkG}==================================================================="
echo -e "${tcLtG} Good $TIME ! ${tcORANGE}                    $ORG"
echo -e "${tcDkG}==================================================================="
echo -e "${tcLtG} Сервер Postgres Pro (СУБД для 1С)"
echo -e "${tcDkG}==================================================================="
echo -e "${tcLtG} - Hostname............:${tcW} $(hostname -f 2>/dev/null || hostname)"
echo -e "${tcLtG} - IP Address..........:${tcW} $IPADDR"
echo -e "${tcLtG} - Release.............:${tcW} $(lsb_release -s -d 2>/dev/null)"
echo -e "${tcLtG} - Kernel..............:${tcW} $(uname -r)"
echo -e "${tcLtG} - Server Time.........:${tcW} $(date)"
echo -e "${tcLtG} - System load.........:${tcW} $LOADS / $PROCS processes"
echo -e "${tcLtG} - Memory used.........:${tcW} $MEMu / $MEMt ($MEMpct)"
echo -e "${tcLtG} - / used..............:${tcW} $ROOTu"
echo -e "${tcLtG} - Swap used...........:${tcW} ${SWAPu:-0} MB"
echo -e "${tcLtG} - Uptime..............:${tcW} $upDays days $upHours hours $upMins minutes"
get_pg_clusters
echo -e "${tcDkG}==================================================================="
echo -e "${tcRESET}"
MOTD_EOF
    } > "$MOTD_FILE"
    chmod +x "$MOTD_FILE"
    : > /etc/motd 2>/dev/null || true   # статичный motd иногда дублирует баннер
    ui_msg "MOTD-баннер установлен: $MOTD_FILE\nПоказывается при входе по SSH.\nПредпросмотр — пункт «Показать»."
}

motd_remove() {
    if [[ -f "$MOTD_FILE" ]]; then
        rm -f "$MOTD_FILE"; ui_msg "MOTD-баннер удалён ($MOTD_FILE)."
    else
        ui_msg "MOTD-баннер не установлен."
    fi
}

motd_preview() {
    if [[ -x "$MOTD_FILE" ]]; then
        ui_msg "$("$MOTD_FILE" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
    else
        ui_msg "MOTD-баннер не установлен. Сначала установите его."
    fi
}

menu_motd() {
    while true; do
        local st="не установлен"; [[ -f "$MOTD_FILE" ]] && st="установлен"
        local c; c=$(ui_menu "MOTD-баннер (сейчас: $st)" "Баннер при входе по SSH" \
            install "Установить / обновить" \
            preview "Показать (предпросмотр)" \
            remove  "Удалить") || return
        case $c in
            install) motd_install ;;
            preview) motd_preview ;;
            remove)  motd_remove ;;
        esac
    done
}

# ─────────────────────── Установка релиза ───────────────────────────
install_release() {
    # Выбор версии: известные + ручной ввод
    local args=() v
    for v in "${KNOWN_VERSIONS[@]}"; do
        discover_installed_versions | grep -qx "$v" && continue
        args+=("$v" "Postgres Pro $v")
    done
    args+=("__manual__" "Ввести версию вручную (1c-N)")
    local choice; choice=$(ui_menu "Установка релиза" "Выберите релиз Postgres Pro 1C" "${args[@]}") || return
    local ver
    if [[ "$choice" == "__manual__" ]]; then
        ver=$(ui_input "Версия релиза (формат 1c-N, напр. 1c-18)" "1c-18") || return
    else
        ver=$choice
    fi
    is_valid_pgver "$ver" || { ui_msg "Неверный формат версии: $ver (ожидается 1c-N)"; return; }
    if discover_installed_versions | grep -qx "$ver"; then
        ui_msg "Релиз $ver уже установлен"; return
    fi
    ui_yesno "Установить Postgres Pro $ver?" || return

    # Локаль ru_RU.UTF-8 обязательна для кластеров 1С (initdb --locale=ru_RU.UTF-8)
    ensure_locales || return

    check_free_space "/opt" 3 || return

    # Зависимости для добавления репозитория
    run_cmd "apt-get install -y curl ca-certificates gnupg lsb-release" "Установка зависимостей репозитория"

    # Репозиторий Postgres Pro. Скрипт pgpro-repo-add.sh завершается с кодом 2,
    # если репозиторий уже добавлен — это не ошибка, в таком случае просто продолжаем.
    if repo_present "$ver"; then
        echo ">>> Репозиторий $ver уже добавлен — пропускаю" >&2
    else
        run_cmd "curl -fsSL '$REPO_BASE/$ver/keys/pgpro-repo-add.sh' -o /tmp/pgpro-repo-add.sh" "Загрузка скрипта репозитория ($ver)" \
            || { ui_msg "Не удалось скачать скрипт репозитория $ver. Проверьте версию и сеть."; return; }
        run_cmd "bash /tmp/pgpro-repo-add.sh" "Добавление репозитория Postgres Pro $ver"
        repo_present "$ver" || { ui_msg "Репозиторий $ver не добавлен (см. $LOG_FILE)."; return; }
    fi
    run_cmd "apt-get update -y" "Обновление индексов пакетов"
    run_cmd "apt-get install -y postgrespro-$ver" "Установка пакетов postgrespro-$ver" || return

    # Проверяем реальный результат
    if [[ ! -x "$PGPRO_BASE/$ver/bin/postgres" ]]; then
        ui_msg "Установка $ver не завершена: не найден $PGPRO_BASE/$ver/bin/postgres.\nПодробности в $LOG_FILE."
        return
    fi

    # Симлинки клиентских/серверных программ
    run_cmd "$PGPRO_BASE/$ver/bin/pg-wrapper links update" "Обновление ссылок (pg-wrapper)"

    # Заморозка пакетов от случайных обновлений
    if ui_yesno "Заморозить (apt-mark hold) пакеты postgrespro-$ver, чтобы их не обновлял apt?"; then
        run_cmd "apt-mark hold $(freeze_pkgs "$ver") 2>/dev/null || true" "Заморозка пакетов $ver"
    fi

    # Дефолтный кластер: пакет postgrespro-<ver> обычно уже инициализирует его сам
    # (каталог /var/lib/pgpro/<ver>/data непустой → повторный initdb упадёт).
    local ddir; ddir=$(instance_datadir "$ver" default)
    if [[ -f "$ddir/PG_VERSION" ]]; then
        if ui_confirm_text "Дефолтный кластер уже инициализирован:\n$ddir\n\nПЕРЕИНИЦИАЛИЗАЦИЯ с --tune=1c УДАЛИТ ВСЕ данные этого кластера БЕЗВОЗВРАТНО." "default"; then
            run_cmd "systemctl stop postgrespro-$ver 2>/dev/null || true" "Остановка postgrespro-$ver"
            run_cmd "rm -rf '$ddir'" "Очистка каталога $ddir"
            run_cmd "'$PGPRO_BASE/$ver/bin/pg-setup' initdb --tune=1c --locale=$DEF_LOCALE" "Переинициализация дефолтного кластера $ver"
        else
            echo ">>> Подтверждение не совпало — оставляю существующий дефолтный кластер без изменений" >&2
        fi
    elif ui_yesno "Инициализировать дефолтный кластер сейчас (pg-setup initdb --tune=1c, locale=$DEF_LOCALE)?"; then
        run_cmd "'$PGPRO_BASE/$ver/bin/pg-setup' initdb --tune=1c --locale=$DEF_LOCALE" "Инициализация дефолтного кластера $ver"
    fi
    # Журналирование (log/ + lc_messages=en_US), контрольные суммы (до старта!), автозапуск и старт
    if [[ -f "$ddir/PG_VERSION" ]]; then
        apply_log_config "$ddir"
        enable_checksums "$ver" "$ddir" "postgrespro-$ver"
        run_cmd "systemctl enable postgrespro-$ver" "Автозапуск postgrespro-$ver"
        run_cmd "systemctl start postgrespro-$ver" "Запуск postgrespro-$ver"
    fi

    ui_msg "Релиз $ver установлен.\nУправление экземплярами — в меню «Экземпляры (кластеры)»."
}

# ─────────────────────── Удаление релиза ────────────────────────────
remove_release() {
    local ver; ver=$(pick_installed_version "Удаление релиза") || return
    ui_yesno "Удалить релиз $ver и ВСЕ его экземпляры?" || return

    # Останавливаем и отключаем все экземпляры релиза
    local u
    while read -r u; do
        [[ -z "$u" ]] && continue
        run_cmd "systemctl stop $u" "Остановка $u"
        run_cmd "systemctl disable $u" "Отключение $u"
        # удаляем кастомные юниты (дефолтный принадлежит пакету)
        if [[ "$u" != "postgrespro-$ver" ]]; then
            rm -f "$SYSTEMD_DIR/$u.service"
            rm -rf "$SYSTEMD_DIR/$u.service.d"
            rm -f "/etc/default/$u"
        fi
    done < <(discover_instances "$ver")
    run_cmd "systemctl daemon-reload" "Перезагрузка systemd"

    run_cmd "apt-mark unhold $(freeze_pkgs "$ver") 2>/dev/null || true" "Снятие заморозки пакетов $ver"
    run_cmd "apt-get remove -y 'postgrespro-$ver*'" "Удаление пакетов $ver"
    [[ -x "$PGPRO_BASE/$ver/bin/pg-wrapper" ]] && run_cmd "$PGPRO_BASE/$ver/bin/pg-wrapper links update" "Обновление ссылок (pg-wrapper)"

    if [[ -d "$DATA_BASE/$ver" ]]; then
        if ui_confirm_text "Удалить ВСЕ каталоги данных релиза: $DATA_BASE/$ver?\nБазы ВСЕХ экземпляров релиза будут БЕЗВОЗВРАТНО удалены." "$ver"; then
            run_cmd "rm -rf '$DATA_BASE/$ver'" "Удаление каталогов данных $ver"
        else
            ui_msg "Каталоги данных $DATA_BASE/$ver СОХРАНЕНЫ (подтверждение не совпало)."
        fi
    fi
    ui_msg "Релиз $ver удалён"
}

# ──────────────── Разморозка пакетов релиза (для обновления) ────────
# Пакеты замораживаются при установке (apt-mark hold), чтобы apt их не трогал.
# Этот пункт снимает заморозку, опционально обновляет и при желании морозит обратно.
freeze_pkgs() { echo "postgrespro-$1 postgrespro-$1-server postgrespro-$1-client postgrespro-$1-contrib postgrespro-$1-libs postgresql-common postgresql-client-common libpq5"; }

unfreeze_release() {
    local ver; ver=$(pick_installed_version "Разморозка пакетов (для обновления)") || return
    local pkgs; pkgs=$(freeze_pkgs "$ver")
    ui_yesno "Снять заморозку (apt-mark unhold) с пакетов $ver, чтобы apt мог их обновлять?\n\n$pkgs" || return
    run_cmd "apt-mark unhold $pkgs 2>/dev/null || true" "Снятие заморозки пакетов $ver"

    if ui_yesno "Обновить пакеты $ver сейчас (apt-get update + upgrade)?"; then
        run_cmd "apt-get update -y" "Обновление индексов пакетов"
        run_cmd "apt-get install -y --only-upgrade postgrespro-$ver" "Обновление пакетов $ver"
        [[ -x "$PGPRO_BASE/$ver/bin/pg-wrapper" ]] && run_cmd "$PGPRO_BASE/$ver/bin/pg-wrapper links update" "Обновление ссылок (pg-wrapper)"
    fi

    if ui_yesno "Заморозить пакеты $ver обратно (apt-mark hold)?"; then
        run_cmd "apt-mark hold $(freeze_pkgs "$ver") 2>/dev/null || true" "Повторная заморозка пакетов $ver"
        ui_msg "Пакеты $ver обновлены и снова заморожены."
    else
        ui_msg "Пакеты $ver разморожены. Заморозить обратно можно позже этим же пунктом меню."
    fi
}

# ──────────────────────── Экземпляры (кластеры) ─────────────────────
list_instances_text() {
    local out="" u ver name datadir port st
    while read -r u; do
        [[ -z "$u" ]] && continue
        ver=$(instance_ver "$u"); name=$(instance_name "$u" "$ver")
        datadir=$(instance_datadir "$ver" "$name"); port=$(instance_port "$datadir")
        st=$(systemctl is-active "$u" 2>/dev/null || echo unknown)
        out+="• $name (релиз $ver, порт $port, $st)\n    юнит: $u\n    данные: $datadir\n"
    done < <(discover_all_instances)
    [[ -z "$out" ]] && out="Экземпляров не найдено.\n"
    echo -e "$out"
}

create_instance() {
    local ver; ver=$(pick_installed_version "Экземпляр: релиз") || return
    local bin; bin=$(pg_bin "$ver")
    [[ -x "$bin/initdb" ]] || { ui_msg "initdb не найден для $ver"; return; }
    local stock; stock=$(stock_unit_path "$ver") || { ui_msg "Штатный systemd-юнит postgrespro-$ver.service не найден"; return; }

    # Локаль ru_RU.UTF-8 обязательна — initdb ниже инициализирует кластер с --locale=$DEF_LOCALE
    ensure_locales || return

    # Имя экземпляра = номер порта (по аналогии с 1С, где имя кодирует идентичность).
    # Подсказываем следующий свободный порт.
    local sp; sp=$(suggest_port)
    local port; port=$(ui_input "Порт нового экземпляра (он же имя экземпляра)" "$sp") || return
    [[ "$port" =~ ^[0-9]+$ ]] || { ui_msg "Порт должен быть числом"; return; }
    local name="$port"
    local unit="postgrespro-$ver-$name"
    local datadir; datadir=$(instance_datadir "$ver" "$name")

    if [[ -f "$SYSTEMD_DIR/$unit.service" ]]; then
        ui_yesno "Экземпляр на порту $port уже существует. Пересоздать?" || return
        run_cmd "systemctl stop $unit 2>/dev/null || true" "Остановка $unit"
    else
        # Новый экземпляр: порт не должен быть занят (слушается или назначен другому экземпляру)
        if port_taken "$port"; then ui_msg "Порт $port уже занят (слушается или назначен другому экземпляру)"; return; fi
    fi

    if [[ -d "$datadir" && -n "$(ls -A "$datadir" 2>/dev/null)" ]]; then
        if ui_confirm_text "Каталог данных $datadir НЕ ПУСТ.\nОчистка и переинициализация УДАЛЯТ его содержимое БЕЗВОЗВРАТНО." "$name"; then
            run_cmd "rm -rf '$datadir'" "Очистка каталога $datadir"
        else
            ui_msg "Подтверждение не совпало — создание отменено, каталог $datadir не тронут."; return
        fi
    fi

    check_free_space "$DATA_BASE" 2 || return
    mkdir -p "$datadir"; chown postgres:postgres "$DATA_BASE/$ver" "$datadir" 2>/dev/null

    # Инициализация кластера от пользователя postgres
    run_cmd "$RUN_AS_PG '$bin/initdb' -D '$datadir' --locale=$DEF_LOCALE --data-checksums" "Инициализация кластера $name ($ver)" || return

    # 1С-тюнинг, журналирование (log/ + lc_messages=en_US) и порт
    apply_1c_tuning "$datadir"
    apply_log_config "$datadir"
    if grep -qE '^[[:space:]]*#?[[:space:]]*port[[:space:]]*=' "$datadir/postgresql.conf"; then
        sed -ri "s/^[[:space:]]*#?[[:space:]]*port[[:space:]]*=.*/port = $port/" "$datadir/postgresql.conf"
    else
        echo "port = $port" >> "$datadir/postgresql.conf"
    fi
    chown -R postgres:postgres "$datadir" 2>/dev/null

    # Штатный юнит берёт PGDATA из /etc/default/postgrespro-<ver> (каталог ДЕФОЛТНОГО
    # кластера) и/или прописывает путь жёстко в ExecStart/PIDFile. Чтобы экземпляр
    # запускался со своим каталогом, делаем три вещи:
    #   1) собственный EnvironmentFile экземпляра с его PGDATA/PGPORT;
    #   2) копию юнита переключаем на этот EnvironmentFile и заменяем в ней жёсткие
    #      пути дефолтного каталога на каталог экземпляра;
    #   3) drop-in с явными PGDATA/PGPORT/PIDFile — как финальная гарантия.
    local defdir; defdir=$(instance_datadir "$ver" default)
    cat > "/etc/default/$unit" <<EOF
PGDATA=$datadir
PGPORT=$port
EOF
    cp "$stock" "$SYSTEMD_DIR/$unit.service"
    sed -i \
        -e "s#/etc/default/postgrespro-$ver\b#/etc/default/$unit#g" \
        -e "s#$defdir#$datadir#g" \
        "$SYSTEMD_DIR/$unit.service"
    mkdir -p "$SYSTEMD_DIR/$unit.service.d"
    cat > "$SYSTEMD_DIR/$unit.service.d/override.conf" <<EOF
[Service]
Environment=PGDATA=${datadir}
Environment=PGPORT=${port}
PIDFile=${datadir}/postmaster.pid
EOF
    run_cmd "systemctl daemon-reload" "Перезагрузка systemd"
    run_cmd "systemctl enable $unit" "Автозапуск экземпляра $name"
    if run_cmd "systemctl start $unit" "Запуск экземпляра $name"; then
        ui_msg "Экземпляр на порту $port создан (имя = $name).\nРелиз: $ver\nКаталог: $datadir\nЮнит: $unit"
    else
        ui_msg "Экземпляр создан, но не запустился. См. journalctl -u $unit"
    fi
}

remove_instance() {
    local u; u=$(pick_instance "Удаление экземпляра") || return
    local ver name datadir
    ver=$(instance_ver "$u"); name=$(instance_name "$u" "$ver"); datadir=$(instance_datadir "$ver" "$name")
    if [[ "$name" == "default" ]]; then
        ui_msg "Дефолтный кластер удаляется вместе с релизом (меню «Удалить релиз»).\nЗдесь удаляются только дополнительные экземпляры."
        return
    fi
    # Подтверждение через ручной ввод номера/имени экземпляра (защита от случайного удаления)
    if ! ui_confirm_text "Удаление экземпляра '$name' (релиз $ver) НЕОБРАТИМО." "$name"; then
        ui_msg "Удаление отменено (подтверждение не совпало)."
        return
    fi
    run_cmd "systemctl stop $u" "Остановка $name"
    run_cmd "systemctl disable $u" "Отключение $name"
    rm -f "$SYSTEMD_DIR/$u.service"
    rm -rf "$SYSTEMD_DIR/$u.service.d"
    rm -f "/etc/default/$u"
    run_cmd "systemctl daemon-reload" "Перезагрузка systemd"
    if [[ -d "$datadir" ]]; then
        if ui_confirm_text "Удалить каталог данных $datadir?\nВсе базы этого экземпляра будут БЕЗВОЗВРАТНО удалены." "$name"; then
            run_cmd "rm -rf '$datadir'" "Удаление каталога данных $name"
        else
            ui_msg "Каталог данных $datadir СОХРАНЁН (подтверждение не совпало)."
        fi
    fi
    ui_msg "Экземпляр '$name' удалён"
}

control_instance() {
    local u; u=$(pick_instance "Управление экземпляром") || return
    local act; act=$(ui_menu "Действие" "Экземпляр: $u" \
        start "Запустить" stop "Остановить" restart "Перезапустить" status "Статус") || return
    case $act in
        start)   run_cmd "systemctl start $u"   "Запуск $u" ;;
        stop)    run_cmd "systemctl stop $u"    "Остановка $u" ;;
        restart) run_cmd "systemctl restart $u" "Перезапуск $u" ;;
        status)  ui_msg "$(systemctl status "$u" --no-pager 2>&1 | head -18)" ;;
    esac
}

# Метод парольной аутентификации по версии: scram-sha-256 для PG ≥ 14
# (формат пароля по умолчанию), md5 для более старых релизов.
pg_local_auth_method() {
    local major; major=$(pgmajor "$1")
    if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 14 )); then echo "scram-sha-256"; else echo "md5"; fi
}

# Включить парольную аутентификацию для локальных подключений (Unix-сокет):
# строка `local all all <method>` в pg_hba.conf, затем reload.
set_local_password_auth() {
    local ver=$1 datadir=$2 unit=$3 method
    local hba="$datadir/pg_hba.conf"
    method=$(pg_local_auth_method "$ver")
    [[ -f "$hba" ]] || return 0
    if grep -qE '^[[:space:]]*local[[:space:]]+all[[:space:]]+all[[:space:]]+' "$hba"; then
        sed -ri "s/^([[:space:]]*local[[:space:]]+all[[:space:]]+all[[:space:]]+)[A-Za-z0-9-]+/\1$method/" "$hba"
    else
        echo "local   all   all   $method" >> "$hba"
    fi
    # на случай более специфичной строки для postgres
    sed -ri "s/^([[:space:]]*local[[:space:]]+all[[:space:]]+postgres[[:space:]]+)[A-Za-z0-9-]+/\1$method/" "$hba"
    run_cmd "systemctl reload $unit" "Перезагрузка конфигурации $unit (pg_hba: local → $method)"
}

# Записать пароль postgres в ~/.pgpass текущего пользователя (для беспарольного psql).
# Привязываем к порту экземпляра, спецсимволы (\ и :) экранируем.
write_pgpass() {
    local port=$1 pass=$2 pgpass="${HOME:-/root}/.pgpass" esc
    esc=${pass//\\/\\\\}; esc=${esc//:/\\:}
    touch "$pgpass"; chmod 600 "$pgpass"
    sed -i "/^localhost:$port:/d; /^127\.0\.0\.1:$port:/d" "$pgpass" 2>/dev/null
    printf 'localhost:%s:*:postgres:%s\n127.0.0.1:%s:*:postgres:%s\n' "$port" "$esc" "$port" "$esc" >> "$pgpass"
    chmod 600 "$pgpass"
}

# Установка пароля postgres через stdin (не светим в ps)
set_postgres_password() {
    local u=$1 ver name datadir port pass
    ver=$(instance_ver "$u"); name=$(instance_name "$u" "$ver")
    datadir=$(instance_datadir "$ver" "$name"); port=$(instance_port "$datadir")
    local bin; bin=$(pg_bin "$ver")
    systemctl is-active --quiet "$u" || { ui_msg "Экземпляр $name не запущен — сначала запустите его"; return; }
    pass=$(ui_password "Новый пароль пользователя postgres (пусто — сгенерировать)") || return
    [[ -z "$pass" ]] && pass=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
    # Пароль уходит через stdin psql, в командной строке его нет.
    # SC2024: redirect в лог выполняет root (владелец $LOG_FILE) — это и требуется.
    # shellcheck disable=SC2024
    if printf "ALTER USER postgres WITH PASSWORD '%s';\n" "$pass" \
        | $RUN_AS_PG "$bin/psql" -v ON_ERROR_STOP=1 -p "$port" -d postgres -f - >>"$LOG_FILE" 2>&1; then
        write_pgpass "$port" "$pass"
        set_local_password_auth "$ver" "$datadir" "$u"
        ui_msg "Пароль пользователя postgres обновлён для экземпляра $name (порт $port).\nПароль: $pass\nЗаписан в ${HOME:-/root}/.pgpass\npg_hba: local all all → $(pg_local_auth_method "$ver")"
    else
        ui_msg "Не удалось установить пароль (см. $LOG_FILE)"
    fi
}

# Изменить порт экземпляра
change_port() {
    local u=$1 ver name datadir cur new
    ver=$(instance_ver "$u"); name=$(instance_name "$u" "$ver")
    datadir=$(instance_datadir "$ver" "$name"); cur=$(instance_port "$datadir")
    new=$(ui_input "Новый порт экземпляра $name" "$cur") || return
    [[ "$new" =~ ^[0-9]+$ ]] || { ui_msg "Порт должен быть числом"; return; }
    if [[ "$new" != "$cur" ]] && ss -tulpn 2>/dev/null | grep -qE ":${new}\b"; then ui_msg "Порт $new уже занят"; return; fi
    if grep -qE '^[[:space:]]*#?[[:space:]]*port[[:space:]]*=' "$datadir/postgresql.conf"; then
        sed -ri "s/^[[:space:]]*#?[[:space:]]*port[[:space:]]*=.*/port = $new/" "$datadir/postgresql.conf"
    else
        echo "port = $new" >> "$datadir/postgresql.conf"
    fi
    run_cmd "systemctl restart $u" "Перезапуск $name (порт $new)"
    ui_msg "Порт экземпляра $name изменён на $new"
}

# Включить/выключить внешний доступ (listen_addresses + pg_hba, scram-sha-256)
toggle_external_access() {
    local u=$1 ver name datadir hba
    ver=$(instance_ver "$u"); name=$(instance_name "$u" "$ver")
    datadir=$(instance_datadir "$ver" "$name"); hba="$datadir/pg_hba.conf"
    local act; act=$(ui_menu "Внешний доступ: $name" "Управление доступом по сети" \
        on  "Включить (listen '*', доступ из подсети)" \
        off "Выключить (только localhost)") || return
    case $act in
        on)
            local subnet; subnet=$(ui_input "Разрешённая подсеть (CIDR)" "0.0.0.0/0") || return
            if grep -qE "^[[:space:]]*#?[[:space:]]*listen_addresses" "$datadir/postgresql.conf"; then
                sed -ri "s/^[[:space:]]*#?[[:space:]]*listen_addresses.*/listen_addresses = '*'/" "$datadir/postgresql.conf"
            else
                echo "listen_addresses = '*'" >> "$datadir/postgresql.conf"
            fi
            grep -qE "^host[[:space:]]+all[[:space:]]+all[[:space:]]+${subnet//./\\.}[[:space:]]+scram-sha-256" "$hba" 2>/dev/null \
                || echo "host all all $subnet scram-sha-256" >> "$hba"
            run_cmd "systemctl restart $u" "Перезапуск $name (внешний доступ вкл)"
            ui_msg "Внешний доступ включён для $name (подсеть $subnet, scram-sha-256).\nНе забудьте задать пароль postgres и открыть порт в брандмауэре."
            ;;
        off)
            sed -ri "s/^[[:space:]]*listen_addresses.*/listen_addresses = 'localhost'/" "$datadir/postgresql.conf" 2>/dev/null
            run_cmd "systemctl restart $u" "Перезапуск $name (внешний доступ выкл)"
            ui_msg "Внешний доступ выключен для $name (listen_addresses = localhost).\nСтроки в pg_hba.conf при необходимости удалите вручную: $hba"
            ;;
    esac
}

configure_instance() {
    local u; u=$(pick_instance "Настройка экземпляра") || return
    while true; do
        local c; c=$(ui_menu "Настройка: $u" "Параметры экземпляра" \
            port     "Изменить порт" \
            password "Задать пароль postgres" \
            access   "Внешний доступ (listen/pg_hba)") || return
        case $c in
            port)     change_port "$u" ;;
            password) set_postgres_password "$u" ;;
            access)   toggle_external_access "$u" ;;
        esac
    done
}

menu_instances() {
    while true; do
        local c; c=$(ui_menu "Экземпляры (кластеры)" "Управление кластерами Postgres Pro" \
            list      "Список экземпляров" \
            create    "Создать экземпляр" \
            remove    "Удалить экземпляр" \
            control   "Запуск/остановка/статус" \
            configure "Настройка (порт/пароль/доступ)") || return
        case $c in
            list)      ui_msg "$(list_instances_text)" ;;
            create)    create_instance ;;
            remove)    remove_instance ;;
            control)   control_instance ;;
            configure) configure_instance ;;
        esac
    done
}

# ───────────────────────────── Главное меню ─────────────────────────
main() {
    while true; do
        CANCEL_LABEL="Выход"
        local c; c=$(ui_menu "Менеджер Postgres Pro 1C" "Выберите действие" \
            setup_os  "Базовая настройка сервера (ОС)" \
            install   "Установить релиз Postgres Pro" \
            remove    "Удалить релиз" \
            unfreeze  "Разморозить пакеты (для обновления)" \
            instances "Экземпляры (кластеры)" \
            ipv6      "IPv6 (включить/отключить)" \
            motd      "MOTD-баннер входа" \
            versions  "Установленные релизы и экземпляры") || { echo "Выход"; exit 0; }
        CANCEL_LABEL="Назад"
        case $c in
            setup_os)  base_setup_os ;;
            install)   install_release ;;
            remove)    remove_release ;;
            unfreeze)  unfreeze_release ;;
            instances) menu_instances ;;
            ipv6)      menu_ipv6 ;;
            motd)      menu_motd ;;
            versions)
                local list; list=$(discover_installed_versions)
                ui_msg "Установленные релизы:\n${list:-нет}\n\nЭкземпляры:\n$(list_instances_text)" ;;
        esac
    done
}

# Запуск меню только при прямом вызове; при `source` (для тестов) — функции доступны без меню
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
