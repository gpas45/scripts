#!/bin/bash
#
# 1c-server-manager.sh — менеджер сервера 1С:Предприятие 8.3 для Linux (Debian/Ubuntu/Astra/Mint)
#
# Объединяет и расширяет:
#   - официальный «Помощник установки и обновления» (с) Уваров А.С., interface31.ru (MIT)
#   - наработки gpas45/scripts по управлению экземплярами
#   - установку веб-модуля (ws) и публикацию баз в Apache
#
# Возможности:
#   • Установка / обновление / удаление платформы (только 8.3.21+)
#   • whiptail/dialog TUI с откатом в консольный режим
#   • Проверка свободного места, компонент v8_install_deps для 8.3.24+, проверка libenchant для <8.3.24
#   • Управление НЕСКОЛЬКИМИ экземплярами (рабочими серверами) через systemd-шаблон
#   • Включение/отключение отладки (-debug -tcp|-http) для ЛЮБОГО экземпляра
#   • Установка ws + Apache (MPM worker) и публикация/снятие публикации баз
#   • Логирование установки в 1c-server-manager.log
#
# Дистрибутивы (setup-full-<версия>-x86_64.run / .zip или server64_<a_b_c_d>.tar.gz/.zip)
# должны лежать в одном каталоге со скриптом.
#
set -o pipefail

# ── Локаль: по умолчанию ru_RU.UTF-8; применяется, если текущая отличается ──
PREFERRED_LOCALE="ru_RU.UTF-8"
if [[ "${LANG:-}" != "$PREFERRED_LOCALE" ]]; then
    if locale -a 2>/dev/null | grep -qiE '^ru_RU\.utf-?8$'; then
        export LANG="$PREFERRED_LOCALE" LC_ALL="$PREFERRED_LOCALE" LANGUAGE="ru_RU:ru"
    elif locale -a 2>/dev/null | grep -qiE '^C\.utf-?8$'; then
        # запасной вариант, если ru_RU.UTF-8 ещё не сгенерирована (свежий сервер)
        export LANG=C.UTF-8 LC_ALL=C.UTF-8
    elif locale -a 2>/dev/null | grep -qiE 'utf-?8'; then
        l=$(locale -a 2>/dev/null | grep -iE 'utf-?8' | head -n1)
        export LANG="$l" LC_ALL="$l"
    fi
fi

# ───────────────────────────── Константы ─────────────────────────────
OPT_BASE="/opt/1cv8/x86_64"
SYSTEMD_DIR="/etc/systemd/system"
MIN_VERSION="8.3.21"
LOG_FILE="1c-server-manager.log"

# Цвета для консольного режима (используются только BLUE и NC)
BLUE='\033[0;34m'; NC='\033[0m'

# Подпись кнопки отмены в меню: на главном — «Выход», в подменю — «Назад»
CANCEL_LABEL="Назад"

# Проверка root
if [[ $EUID -ne 0 ]]; then
    echo "Запустите скрипт от имени root"; exit 1
fi

# Проверка архитектуры (требуется amd64 / x86_64)
arch=$(dpkg --print-architecture 2>/dev/null || true)
if [[ -n "$arch" ]]; then
    [[ "$arch" != "amd64" ]] && { echo "Архитектура $arch не поддерживается. Требуется amd64"; exit 1; }
else
    machine=$(uname -m 2>/dev/null || echo "")
    [[ -n "$machine" && "$machine" != "x86_64" ]] && { echo "Архитектура $machine не поддерживается"; exit 1; }
fi

# Инструмент TUI (whiptail или dialog), если установлен
DIALOG=$(command -v whiptail || command -v dialog || true)

# Рабочий каталог = каталог скрипта (где лежат дистрибутивы)
cd "$(dirname "$0")" || exit 1

# ───────────────────────── UI-слой (TUI/консоль) ────────────────────
# Все диалоги идут через эти обёртки: при наличии whiptail/dialog — графика, иначе консоль.

# ВАЖНО: whiptail рисует интерфейс в stdout. Эти функции часто вызываются внутри
# $(...) (захват stdout), поэтому UI принудительно направляем в терминал (stderr/ /dev/tty),
# иначе окно «съедается» подстановкой и получается чёрный экран.

ui_msg() { # ui_msg "текст"
    if [[ -n "$DIALOG" ]]; then "$DIALOG" --msgbox "$1" 14 76 1>&2; else echo -e "$1" >&2; fi
}

ui_yesno() { # ui_yesno "вопрос" -> 0 (да) / 1 (нет)
    if [[ -n "$DIALOG" ]]; then
        "$DIALOG" --yesno "$1" 12 76 1>&2
    else
        local a; read -rp "$1 (y/N): " a </dev/tty 2>/dev/tty; [[ $a =~ ^[Yy] ]]
    fi
}

ui_input() { # ui_input "запрос" "значение_по_умолчанию" -> echo результата
    local prompt=$1 def=$2 res
    if [[ -n "$DIALOG" ]]; then
        res=$("$DIALOG" --inputbox "$prompt" 10 76 "$def" 3>&1 1>&2 2>&3) || return 1
    else
        read -rp "$prompt [${def}]: " res </dev/tty 2>/dev/tty; res=${res:-$def}
    fi
    echo "$res"
}

# ui_menu "заголовок" "подпись" tag1 "название1" tag2 "название2" ... -> echo выбранного tag
# Пользователь видит только названия (нумерованный список), внутренние tag'и скрыты.
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
              --menu "\n$text" "$h" 74 "$n" "${margs[@]}" 3>&1 1>&2 2>&3) || return 1
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

# Запуск команды с ПОКАЗОМ реального вывода (apt/установщик видно вживую) + лог.
run_cmd() { # run_cmd "команда" "описание"
    local command=$1 desc=$2 rc tmp="/tmp/1c_run_$$.out"
    echo "=== $(date '+%F %T') :: $desc" >> "$LOG_FILE"
    echo "CMD: $command" >> "$LOG_FILE"
    echo  >&2
    echo "──────────────────────────────────────────────────────────" >&2
    echo ">>> $desc" >&2
    echo "──────────────────────────────────────────────────────────" >&2
    # вывод одновременно на экран (терминал) и в файл-лог
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
is_valid_version() { [[ $1 =~ ^8\.3\.[0-9]{2}\.[0-9]{4}$ ]]; }

# $1 >= MIN_VERSION ?
version_supported() {
    [[ "$(printf '%s\n%s\n' "$MIN_VERSION" "$1" | sort -V | head -n1)" == "$MIN_VERSION" ]]
}

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

# Надёжная проверка установленного пакета (вместо разбора `dpkg -l | grep`)
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
# Apache считаем установленным, если есть бинарь apache2ctl или пакет apache2
apache_installed() { command -v apache2ctl >/dev/null 2>&1 || [[ -x /usr/sbin/apache2ctl ]] || pkg_installed apache2; }

# Установленные версии (есть uninstaller-full)
discover_installed_versions() {
    [[ -d "$OPT_BASE" ]] || return 0
    find "$OPT_BASE" -maxdepth 1 -mindepth 1 -type d -printf "%f\n" 2>/dev/null | while read -r v; do
        [[ $v =~ ^8\.3\.[0-9]{2}\.[0-9]{4}$ && -f "$OPT_BASE/$v/uninstaller-full" ]] && echo "$v"
    done | sort -rV
}

# Доступные для установки дистрибутивы в каталоге (не считая уже установленных)
discover_install_versions() {
    local installed file v arc
    installed=$(discover_installed_versions)
    shopt -s nullglob
    for file in setup-full-*-x86_64.run setup-full-*-x86_64.zip; do
        v=${file#setup-full-}; v=${v%-x86_64.run}; v=${v%-x86_64.zip}
        echo "$installed" | grep -qx "$v" || echo "$v"
    done
    for file in server64_*.tar.gz server64_*.zip; do
        arc=${file#server64_}; arc=${arc%.tar.gz}; arc=${arc%.zip}; v=${arc//_/.}
        echo "$installed" | grep -qx "$v" || echo "$v"
    done
    shopt -u nullglob
}

# Все экземпляры (юниты вида srv1cv8-<ver>@<name>)
discover_instances() {
    systemctl list-units --all --no-legend --no-pager --plain 'srv1cv8-*@*' 2>/dev/null \
        | awk '{print $1}' | sed 's/\.service$//' | grep -E 'srv1cv8-8\.3\.' | sort -u
}

# Выбор версии из установленных через UI; echo -> версия, return 1 при отмене/отсутствии
pick_installed_version() {
    local title=${1:-"Выбор версии"}
    mapfile -t vers < <(discover_installed_versions)
    (( ${#vers[@]} == 0 )) && { ui_msg "Установленные версии платформы не найдены"; return 1; }
    local args=() v
    for v in "${vers[@]}"; do args+=("$v" "версия $v"); done
    ui_menu "$title" "Выберите версию платформы" "${args[@]}"
}

# Информативная подпись экземпляра для меню: имя · версия · порт · статус · отладка
instance_desc() {
    local u=$1 nm ver port st dbg
    nm=${u##*@}; ver=$(echo "$u" | grep -oP 'srv1cv8-\K[0-9.]+(?=@)')
    st=$(systemctl is-active "$u" 2>/dev/null || echo "?")
    port=$(systemctl show "$u" -p Environment --no-pager 2>/dev/null | grep -oP 'SRV1CV8_PORT=\K[0-9]+')
    dbg=$(get_debug_state "$ver" "$nm")
    echo "$nm · v$ver · порт ${port:-1540} · $st · отладка:$dbg"
}

# ─────────────────── Распаковка дистрибутива в .run ──────────────────
# Архивы распаковываются в подпапку с именем версии (например ./8.3.25.1257),
# исходные архивы НЕ удаляются. Путь к найденному .run возвращается в RUN_FILE.
RUN_FILE=""
prepare_run() {
    local newver=$1 arcname verdir
    arcname=${newver//./_}
    verdir="./$newver"          # ВАЖНО: отдельной строкой (в одной строке local взял бы пустой $newver)
    RUN_FILE=""

    # 1) .run уже лежит прямо в каталоге со скриптом
    if [[ -f "setup-full-$newver-x86_64.run" ]]; then
        RUN_FILE="./setup-full-$newver-x86_64.run"
        echo ">>> Используется готовый дистрибутив (без распаковки): $RUN_FILE" >&2
        return 0
    fi
    # 2) .run уже распакован в папке версии — переиспользуем, повторно НЕ распаковываем
    if [[ -f "$verdir/setup-full-$newver-x86_64.run" ]]; then
        RUN_FILE="$verdir/setup-full-$newver-x86_64.run"
        echo ">>> Используется ранее распакованный дистрибутив (без распаковки): $RUN_FILE" >&2
        return 0
    fi

    # 3) распаковываем архив В ПАПКУ ВЕРСИИ (архив оставляем на месте)
    if [[ -f "server64_$arcname.tar.gz" ]]; then
        check_free_space "." 2 || return 1
        mkdir -p "$verdir"
        run_cmd "tar -xzf server64_$arcname.tar.gz -C '$verdir'" "Распаковка server64_$arcname.tar.gz в $verdir" || return 1
        if [[ -f "$verdir/setup-full-$newver-x86_64.zip" ]]; then
            command -v unzip >/dev/null || run_cmd "apt-get update -y && apt-get install -y unzip" "Установка unzip"
            run_cmd "unzip -o '$verdir/setup-full-$newver-x86_64.zip' -d '$verdir'" "Распаковка вложенного архива" || return 1
        fi
    elif [[ -f "server64_$arcname.zip" ]]; then
        check_free_space "." 2 || return 1
        command -v unzip >/dev/null || run_cmd "apt-get update -y && apt-get install -y unzip" "Установка unzip"
        mkdir -p "$verdir"
        run_cmd "unzip -o server64_$arcname.zip -d '$verdir'" "Распаковка server64_$arcname.zip в $verdir" || return 1
    elif [[ -f "setup-full-$newver-x86_64.zip" ]]; then
        command -v unzip >/dev/null || run_cmd "apt-get update -y && apt-get install -y unzip" "Установка unzip"
        mkdir -p "$verdir"
        run_cmd "unzip -o setup-full-$newver-x86_64.zip -d '$verdir'" "Распаковка setup-full-$newver-x86_64.zip в $verdir" || return 1
    else
        return 1
    fi

    # Ищем .run в папке версии (в т.ч. во вложенном каталоге)
    if [[ -f "$verdir/setup-full-$newver-x86_64.run" ]]; then
        RUN_FILE="$verdir/setup-full-$newver-x86_64.run"; return 0
    fi
    local found; found=$(find "$verdir" -maxdepth 3 -name "setup-full-$newver-x86_64.run" -print -quit 2>/dev/null)
    [[ -n "$found" ]] && { RUN_FILE="$found"; return 0; }
    return 1
}

# Проверка libenchant1c2a (нужна только для версий < 8.3.24)
ensure_libenchant() {
    [[ "$(lsb_release -si 2>/dev/null)" =~ ^AstraLinux ]] && return 0
    dpkg -s libenchant1c2a &>/dev/null && return 0
    local codename; codename=$(lsb_release -sc 2>/dev/null)
    case $codename in
        stretch|buster|bionic|focal|tara|tessa|tina|tricia|ulyana|ulyssa|uma|una)
            run_cmd "apt-get update -y && apt-get install -y libenchant1c2a" "Установка libenchant1c2a" ;;
        *)
            run_cmd "apt-get install -y libenchant1c2a || apt-get install -y libenchant-2-2" "Установка libenchant" \
                || ui_msg "libenchant1c2a недоступен в репозиториях. При проблемах подключите репозиторий Debian buster вручную." ;;
    esac
    return 0
}

# ─────────────────────── Удаление платформы ─────────────────────────
remove_platform() {
    local ver=$1
    [[ -d "$OPT_BASE/$ver" ]] || { ui_msg "Версия $ver не найдена"; return 1; }
    # Останавливаем и отключаем все экземпляры этой версии
    local u
    while read -r u; do
        [[ -z "$u" ]] && continue
        run_cmd "systemctl stop $u" "Остановка $u"
        run_cmd "systemctl disable $u" "Отключение $u"
    done < <(systemctl list-units --all --no-legend --plain "srv1cv8-$ver@*" 2>/dev/null | awk '{print $1}')
    systemctl disable "srv1cv8-$ver@" 2>/dev/null
    rm -rf "$SYSTEMD_DIR/srv1cv8-$ver@"*.service.d 2>/dev/null

    # Штатный деинсталлятор работает только при наличии uninstaller-full.dat.
    # Если он отсутствует/сломан — удаляем каталог платформы вручную, чтобы не блокировать обновление.
    local removed=0
    if [[ -x "$OPT_BASE/$ver/uninstaller-full" && -f "$OPT_BASE/$ver/uninstaller-full.dat" ]]; then
        run_cmd "$OPT_BASE/$ver/uninstaller-full --mode unattended" "Удаление платформы $ver" && removed=1
    fi
    if [[ $removed -eq 0 && -d "$OPT_BASE/$ver" ]]; then
        run_cmd "rm -rf '$OPT_BASE/$ver'" "Ручное удаление каталога $OPT_BASE/$ver (деинсталлятор недоступен)"
    fi
    rm -f "$SYSTEMD_DIR/srv1cv8-$ver@.service" 2>/dev/null
    run_cmd "systemctl daemon-reload" "Перезагрузка systemd"
    ui_msg "Платформа $ver удалена"
}

# Предпроверка окружения: lsb-release и локаль ru_RU.UTF-8.
# При несоответствии — предупреждение и предложение выполнить базовую настройку.
precheck_environment() {
    local issues=""
    command -v lsb_release >/dev/null 2>&1 || issues+="• Пакет lsb-release не установлен\n"
    if ! [[ "${LANG,,}" =~ ^ru_ru\.utf-?8 ]]; then
        issues+="• Текущая локаль «${LANG:-не задана}» отличается от ru_RU.UTF-8\n"
    fi
    if [[ -n "$issues" ]]; then
        if ui_yesno "Перед установкой рекомендуется базовая настройка сервера:\n\n${issues}\nВыполнить базовую настройку сейчас?"; then
            base_setup_os
        fi
    fi
}

# ─────────────────────── Установка платформы ────────────────────────
install_platform() {
    local newver=$1 oldver=$2     # oldver — для обновления конфигурации Apache (может быть пусто)

    is_valid_version "$newver" || { ui_msg "Неверный формат версии: $newver"; return 1; }
    version_supported "$newver" || { ui_msg "Поддерживаются только версии $MIN_VERSION и выше"; return 1; }

    precheck_environment

    prepare_run "$newver" || { ui_msg "Не обнаружен дистрибутив платформы $newver"; return 1; }

    # Веб-модуль на этапе установки?
    local web="no"
    ui_yesno "Установить также модуль расширения веб-сервера (ws)?" && web="yes"

    # Состав компонентов
    local components="--mode unattended --enable-components server"
    [[ $web == "yes" ]] && components="--mode unattended --enable-components server,ws"
    # Для 8.3.24+ платформа умеет ставить свои зависимости сама
    if version_supported "$newver" && [[ "$(printf '%s\n8.3.24\n' "$newver" | sort -V | head -n1)" == "8.3.24" ]]; then
        components="$components,v8_install_deps"
    fi

    # Apache для веб-модуля
    if [[ $web == "yes" ]] && ! apache_installed; then
        if ui_yesno "Apache не найден. Установить apache2?"; then
            run_cmd "apt-get update -y && apt-get install -y apache2" "Установка Apache2"
            run_cmd "systemctl enable apache2 && systemctl start apache2" "Запуск Apache2"
        fi
    fi

    # libenchant только для < 8.3.24
    if [[ "$(printf '%s\n8.3.24\n' "$newver" | sort -V | head -n1)" == "$newver" && "$newver" != "8.3.24"* ]]; then
        ensure_libenchant
    fi

    # Проверка места и запуск установщика (путь к .run — в RUN_FILE, может быть в папке версии)
    chmod +x "$RUN_FILE"
    check_free_space "/opt" 5 || return 1
    run_cmd "'$RUN_FILE' $components" "Установка платформы $newver"

    # Проверяем реальный результат по наличию ragent: установщик 1С иногда
    # возвращает ненулевой код из-за некритичных шагов (особенно в контейнерах).
    if [[ ! -x "$OPT_BASE/$newver/ragent" ]]; then
        ui_msg "Установка платформы $newver не завершена: не найден $OPT_BASE/$newver/ragent.\nПодробности в $LOG_FILE."
        return 1
    fi

    # Регистрация systemd-шаблона (имя/путь ищем фактически)
    local tmpl="$OPT_BASE/$newver/srv1cv8-$newver@.service"
    [[ -f "$tmpl" ]] || tmpl=$(find "$OPT_BASE/$newver" -maxdepth 1 -name 'srv1cv8-*@.service' -print -quit 2>/dev/null)
    if [[ -n "$tmpl" && -f "$tmpl" ]]; then
        run_cmd "systemctl link '$tmpl'" "Регистрация службы 1С"
        run_cmd "systemctl enable srv1cv8-$newver@" "Автозапуск службы 1С"
        run_cmd "systemctl start srv1cv8-$newver@default" "Запуск экземпляра default"
    else
        ui_msg "Платформа установлена, но systemd-шаблон srv1cv8-$newver@.service не найден.\nЭкземпляр по умолчанию не создан — проверьте, что устанавливалась компонента server."
    fi

    # При обновлении — поправить версию в конфиге Apache
    if [[ $web == "yes" && -n "$oldver" && -f /etc/apache2/apache2.conf && $oldver =~ ^8\.3\. ]]; then
        run_cmd "sed -i 's|${oldver//./\\.}|$newver|g' /etc/apache2/apache2.conf && systemctl restart apache2" "Обновление конфигурации Apache"
    fi

    # Дистрибутивы и распакованные файлы НЕ удаляем (сохраняем в папке версии)
    ui_msg "Платформа $newver установлена.\nЭкземпляр по умолчанию: srv1cv8-$newver@default\nИсходные архивы и распакованные файлы сохранены."
}

# ──────────────────────── Меню: платформа ───────────────────────────
menu_install() {
    mapfile -t found < <(discover_install_versions | sort -uV)
    (( ${#found[@]} == 0 )) && { ui_msg "В каталоге нет новых дистрибутивов платформы.\nВсе найденные версии уже установлены."; return; }
    local args=() v
    for v in "${found[@]}"; do args+=("$v" "$v — дистрибутив в каталоге"); done
    local newver; newver=$(ui_menu "Установка" "Выберите версию для установки" "${args[@]}") || return
    ui_yesno "Установить платформу $newver?" || return
    install_platform "$newver" ""
}

menu_upgrade() {
    # Доступные новые дистрибутивы (уже установленные версии исключаются автоматически)
    mapfile -t found < <(discover_install_versions | sort -uV)
    (( ${#found[@]} == 0 )) && { ui_msg "Нет новых дистрибутивов для обновления.\nВсе найденные в каталоге версии уже установлены — обновлять нечего."; return; }
    local args=() v
    for v in "${found[@]}"; do args+=("$v" "$v — установить"); done
    local newver; newver=$(ui_menu "Обновление" "Выберите новую версию для установки" "${args[@]}") || return

    # Какую установленную версию удалить перед установкой (можно не удалять)
    mapfile -t inst < <(discover_installed_versions)
    local oldver=""
    if (( ${#inst[@]} > 0 )); then
        local iargs=()
        for v in "${inst[@]}"; do iargs+=("$v" "$v — удалить"); done
        iargs+=("__none__" "не удалять (поставить рядом)")
        oldver=$(ui_menu "Обновление" "Удалить установленную версию перед установкой $newver?" "${iargs[@]}") || return
        [[ "$oldver" == "__none__" ]] && oldver=""
    fi

    if [[ -n "$oldver" ]]; then
        ui_yesno "Версия $oldver будет удалена, затем установлена $newver. Продолжить?" || return
        remove_platform "$oldver"
    else
        ui_yesno "Будет установлена $newver (без удаления других версий). Продолжить?" || return
    fi
    install_platform "$newver" "$oldver"
}

menu_delete() {
    local ver; ver=$(pick_installed_version "Удаление платформы") || return
    ui_yesno "Удалить платформу $ver?" || return
    remove_platform "$ver"
}

# ──────────────────────── Меню: экземпляры ──────────────────────────
list_instances_text() {
    local out="" u inst ver st port dbg
    while read -r u; do
        [[ -z "$u" ]] && continue
        inst=${u##*@}; ver=$(echo "$u" | grep -oP 'srv1cv8-\K[0-9.]+(?=@)')
        st=$(systemctl is-active "$u" 2>/dev/null || echo unknown)
        port=$(systemctl show "$u" --property=Environment --no-pager 2>/dev/null | grep -oP 'SRV1CV8_PORT=\K[0-9]+')
        dbg=$(get_debug_state "$ver" "$inst")
        out+="• $inst (v$ver, порт ${port:-1540}, $st, отладка: $dbg)\n"
    done < <(discover_instances)
    [[ -z "$out" ]] && out="Экземпляров не найдено.\n"
    echo -e "$out"
}

# Следующее свободное имя экземпляра Nx (2x, 3x, …) и порты N540/N541/N560:N591.
# default = «1x» (порты 1540/1541), поэтому новые начинаются с 2x.
suggest_instance() {
    local ver=$1 n=2 name
    while (( n < 90 )); do
        name="${n}x"
        if [[ ! -e "$SYSTEMD_DIR/srv1cv8-$ver@$name.service.d" ]] \
           && ! ss -tulpn 2>/dev/null | grep -qE ":${n}540\b" \
           && ! ss -tulpn 2>/dev/null | grep -qE ":${n}541\b"; then
            echo "$name ${n}540 ${n}541 ${n}560:${n}591"
            return 0
        fi
        ((n++))
    done
    echo "2x 2540 2541 2560:2591"
}

create_instance() {
    local ver; ver=$(pick_installed_version "Экземпляр: версия платформы") || return
    [[ -f "$OPT_BASE/$ver/srv1cv8-$ver@.service" ]] || { ui_msg "Шаблон службы для $ver не найден"; return; }
    run_cmd "systemctl link $OPT_BASE/$ver/srv1cv8-$ver@.service" "Регистрация шаблона $ver"

    # Подсказка следующего свободного имени и портов
    local sn sp srp srr
    read -r sn sp srp srr < <(suggest_instance "$ver")

    local name port regport range
    name=$(ui_input "Имя нового экземпляра (латиницей; default зарезервирован)" "$sn") || return
    [[ -z "$name" ]] && { ui_msg "Имя не может быть пустым"; return; }
    local override="$SYSTEMD_DIR/srv1cv8-$ver@$name.service.d/override.conf"
    if [[ -f "$override" ]]; then
        ui_yesno "Экземпляр $name уже существует. Перезаписать?" || return
    fi
    port=$(ui_input "Порт агента" "$sp") || return
    regport=$(ui_input "Регистрационный порт" "$srp") || return
    range=$(ui_input "Диапазон портов" "$srr") || return

    if ss -tulpn 2>/dev/null | grep -qE ":${port}\b"; then ui_msg "Порт $port уже занят"; return; fi
    if ss -tulpn 2>/dev/null | grep -qE ":${regport}\b"; then ui_msg "Порт $regport уже занят"; return; fi

    local data_dir="/home/usr1cv8/.1cv8/1C/1cv8_${name}"
    mkdir -p "$data_dir"; chown -R usr1cv8:grp1cv8 "$data_dir" 2>/dev/null
    mkdir -p "$SYSTEMD_DIR/srv1cv8-$ver@$name.service.d"
    cat > "$override" <<EOF
[Service]
Environment=SRV1CV8_DATA=${data_dir}
Environment=SRV1CV8_PORT=${port}
Environment=SRV1CV8_REGPORT=${regport}
Environment=SRV1CV8_RANGE=${range}
EOF
    run_cmd "systemctl daemon-reload" "Перезагрузка systemd"
    run_cmd "systemctl enable srv1cv8-$ver@$name" "Автозапуск экземпляра $name"
    if run_cmd "systemctl start srv1cv8-$ver@$name" "Запуск экземпляра $name"; then
        ui_msg "Экземпляр '$name' создан.\nВерсия: $ver\nПорт: $port, регпорт: $regport, диапазон: $range\nКаталог: $data_dir"
    else
        ui_msg "Экземпляр создан, но не запустился. См. journalctl -u srv1cv8-$ver@$name"
    fi
}

remove_instance() {
    mapfile -t inst < <(discover_instances)
    (( ${#inst[@]} == 0 )) && { ui_msg "Экземпляров не найдено"; return; }
    local args=() u nm
    for u in "${inst[@]}"; do args+=("$u" "$(instance_desc "$u")"); done
    local chosen; chosen=$(ui_menu "Удаление экземпляра" "Выберите экземпляр" "${args[@]}") || return
    local ver name; ver=$(echo "$chosen" | grep -oP 'srv1cv8-\K[0-9.]+(?=@)'); name=${chosen##*@}
    [[ "$name" == "default" ]] && { ui_yesno "Удалить экземпляр default? (обычно не нужно)" || return; }
    run_cmd "systemctl stop $chosen" "Остановка $name"
    run_cmd "systemctl disable $chosen" "Отключение $name"
    rm -rf "$SYSTEMD_DIR/srv1cv8-$ver@$name.service.d"
    run_cmd "systemctl daemon-reload" "Перезагрузка systemd"
    local data_dir="/home/usr1cv8/.1cv8/1C/1cv8_${name}"
    if [[ -d "$data_dir" ]] && ui_yesno "Удалить каталог данных $data_dir?"; then rm -rf "$data_dir"; fi
    ui_msg "Экземпляр '$name' удалён"
}

control_instance() {
    mapfile -t inst < <(discover_instances)
    (( ${#inst[@]} == 0 )) && { ui_msg "Экземпляров не найдено"; return; }
    local args=() u nm
    for u in "${inst[@]}"; do args+=("$u" "$(instance_desc "$u")"); done
    local chosen; chosen=$(ui_menu "Управление экземпляром" "Выберите экземпляр" "${args[@]}") || return
    local act; act=$(ui_menu "Действие" "Экземпляр: $chosen" \
        start "Запустить" stop "Остановить" restart "Перезапустить" status "Статус") || return
    case $act in
        start)   run_cmd "systemctl start $chosen"   "Запуск $chosen" ;;
        stop)    run_cmd "systemctl stop $chosen"    "Остановка $chosen" ;;
        restart) run_cmd "systemctl restart $chosen" "Перезапуск $chosen" ;;
        status)  ui_msg "$(systemctl status "$chosen" --no-pager 2>&1 | head -15)" ;;
    esac
}

menu_instances() {
    while true; do
        local c; c=$(ui_menu "Экземпляры (рабочие серверы)" "Управление экземплярами 1С" \
            list   "Список экземпляров" \
            create "Создать экземпляр" \
            remove "Удалить экземпляр" \
            control "Запуск/остановка/статус") || return
        case $c in
            list)    ui_msg "$(list_instances_text)" ;;
            create)  create_instance ;;
            remove)  remove_instance ;;
            control) control_instance ;;
        esac
    done
}

# ──────────────────────── Меню: отладка ─────────────────────────────
# Состояние отладки экземпляра: off | tcp | http
get_debug_state() {
    local ver=$1 name=${2##*@}     # на случай, если передали полное имя юнита — берём только имя экземпляра
    local f="$SYSTEMD_DIR/srv1cv8-$ver@$name.service.d/override.conf"
    [[ -f "$f" ]] || { echo off; return; }
    if grep -q 'SRV1CV8_DEBUG=.*-http' "$f"; then echo http
    elif grep -q 'SRV1CV8_DEBUG=.*-debug' "$f"; then echo tcp
    else echo off; fi
}

set_debug() {
    local ver=$1 name=${2##*@} mode=$3 f     # name — только имя экземпляра (без srv1cv8-…@)
    # Чистим ошибочные drop-in каталоги с задвоенным именем (баг прежних версий)
    rm -rf "$SYSTEMD_DIR"/srv1cv8-*@srv1cv8-*.service.d 2>/dev/null
    local dir="$SYSTEMD_DIR/srv1cv8-$ver@$name.service.d"
    f="$dir/override.conf"; mkdir -p "$dir"
    [[ -f "$f" ]] || echo "[Service]" > "$f"
    sed -i '/SRV1CV8_DEBUG=/d' "$f"
    case $mode in
        tcp)  echo 'Environment=SRV1CV8_DEBUG="-debug -tcp"'  >> "$f" ;;
        http) echo 'Environment=SRV1CV8_DEBUG="-debug -http"' >> "$f" ;;
        off)  : ;;
    esac
    run_cmd "systemctl daemon-reload" "Перезагрузка systemd"
    run_cmd "systemctl restart srv1cv8-$ver@$name" "Перезапуск srv1cv8-$ver@$name"
}

menu_debug() {
    while true; do
        mapfile -t inst < <(discover_instances)
        (( ${#inst[@]} == 0 )) && { ui_msg "Экземпляров не найдено. Сначала установите платформу/создайте экземпляр."; return; }
        local args=() u
        for u in "${inst[@]}"; do args+=("$u" "$(instance_desc "$u")"); done
        local chosen; chosen=$(ui_menu "Отладка экземпляров" "Выберите экземпляр (Назад — выход)" "${args[@]}") || return
        local nm ver state
        ver=$(echo "$chosen" | grep -oP 'srv1cv8-\K[0-9.]+(?=@)'); nm=${chosen##*@}
        state=$(get_debug_state "$ver" "$nm")

        local choice
        if [[ $state == off ]]; then
            choice=$(ui_menu "Отладка: $nm (сейчас выключена)" "Включить отладку сервера:" \
                tcp "Включить TCP" http "Включить HTTP") || continue
        else
            choice=$(ui_menu "Отладка: $nm (сейчас включена — $state)" "Изменить отладку:" \
                off "Выключить" tcp "Переключить на TCP" http "Переключить на HTTP") || continue
        fi
        local odir="$SYSTEMD_DIR/srv1cv8-$ver@$nm.service.d/override.conf"
        case $choice in
            tcp)  set_debug "$ver" "$nm" tcp;  ui_msg "Отладка (TCP) включена ТОЛЬКО для экземпляра $nm.\nФайл: $odir\nСлужба перезапущена." ;;
            http) set_debug "$ver" "$nm" http; ui_msg "Отладка (HTTP) включена ТОЛЬКО для экземпляра $nm.\nФайл: $odir\nСлужба перезапущена." ;;
            off)  set_debug "$ver" "$nm" off;  ui_msg "Отладка выключена для экземпляра $nm.\nСлужба перезапущена." ;;
        esac
    done
}

# ──────────────────────── Меню: веб-модуль ──────────────────────────
# Опубликованная база = каталог в /var/www с файлом публикации default.vrd
list_published_names() {
    local d
    for d in /var/www/*/; do
        [[ -f "${d}default.vrd" ]] && basename "$d"
    done 2>/dev/null
}
list_published() {
    local out="" n
    while read -r n; do
        [[ -z "$n" ]] && continue
        out+="• $n   →   /var/www/$n   (http://<сервер>/$n)\n"
    done < <(list_published_names)
    [[ -z "$out" ]] && out="Опубликованных баз не найдено."
    echo -e "$out"
}

web_install() {
    local ver; ver=$(pick_installed_version "Веб-модуль: версия") || return
    if ! apache_installed; then
        run_cmd "apt-get update -y && apt-get install -y apache2" "Установка Apache2"
        run_cmd "systemctl enable apache2" "Автозапуск Apache2"
    else
        ui_msg "Apache уже установлен — пропускаю установку."
    fi
    # MPM worker
    local mpm
    for mpm in $(apache2ctl -M 2>/dev/null | grep mpm_ | awk '{print $1}' | sed 's/_module//'); do
        a2dismod -q "$mpm" >/dev/null 2>&1
    done
    a2enmod -q mpm_worker >/dev/null 2>&1
    run_cmd "systemctl restart apache2" "Настройка MPM worker"
    # Компонента ws
    if [[ -f "$OPT_BASE/$ver/ws/apache2.4/wsap24.so" || -f "$OPT_BASE/$ver/ws/apache2.4/mod_1c.so" ]]; then
        ui_msg "Компонента ws для $ver уже установлена"
    else
        prepare_run "$ver" || { ui_msg "Дистрибутив $ver для установки ws не найден"; return; }
        chmod +x "$RUN_FILE"
        if run_cmd "'$RUN_FILE' --mode unattended --enable-components ws" "Установка компоненты ws"; then
            ui_msg "Компонента ws установлена"
        else
            ui_msg "Ошибка установки ws (см. $LOG_FILE)"
        fi
    fi
}

web_publish() {
    local ver; ver=$(pick_installed_version "Публикация: версия") || return
    [[ -f "$OPT_BASE/$ver/webinst" ]] || { ui_msg "webinst не найден для $ver (установите ws)"; return; }
    local cur; cur=$(list_published)
    [[ "$cur" != "Опубликованных баз не найдено." ]] && ui_msg "Уже опубликованы:\n\n$cur"
    local ib srv ref dir
    ib=$(ui_input "Имя публикации/базы (латиницей)" "") || return
    [[ -z "$ib" ]] && { ui_msg "Имя не может быть пустым"; return; }
    srv=$(ui_input "Адрес сервера 1С (Srvr)" "localhost") || return
    ref=$(ui_input "Имя базы на сервере (Ref)" "$ib") || return
    dir="/var/www/$ib"; mkdir -p "$dir"
    if run_cmd "$OPT_BASE/$ver/webinst -publish -apache24 -wsdir '$ib' -dir '$dir' -connstr 'Srvr=$srv;Ref=$ref;' -confPath /etc/apache2/apache2.conf" \
        "Публикация базы $ib"; then
        chown -R www-data:www-data "$dir"
        run_cmd "systemctl restart apache2" "Перезапуск Apache2"
        ui_msg "База опубликована: http://<сервер>/$ib"
    else
        ui_msg "Ошибка публикации (см. $LOG_FILE)"
    fi
}

web_unpublish() {
    mapfile -t pubs < <(list_published_names)
    (( ${#pubs[@]} == 0 )) && { ui_msg "Опубликованных баз не найдено."; return; }
    local args=() p
    for p in "${pubs[@]}"; do args+=("$p" "$p   →   /var/www/$p"); done
    local ib; ib=$(ui_menu "Снятие публикации" "Выберите базу для снятия" "${args[@]}") || return
    local ver; ver=$(discover_installed_versions | head -n1)
    [[ -n "$ver" && -f "$OPT_BASE/$ver/webinst" ]] || { ui_msg "webinst не найден (нужна установленная платформа с ws)"; return; }
    local dir="/var/www/$ib"
    ui_yesno "Снять публикацию «$ib» и удалить каталог $dir?" || return
    run_cmd "$OPT_BASE/$ver/webinst -delete -apache24 -wsdir '$ib' -dir '$dir' -confPath /etc/apache2/apache2.conf" "Снятие публикации $ib"
    rm -rf "$dir"
    run_cmd "systemctl restart apache2" "Перезапуск Apache2"
    ui_msg "Публикация «$ib» снята"
}

menu_web() {
    while true; do
        local c; c=$(ui_menu "Веб-модуль (Apache)" "Публикация баз через веб-сервер" \
            install   "Установить ws + Apache + MPM worker" \
            list      "Список опубликованных баз" \
            publish   "Опубликовать базу" \
            unpublish "Снять публикацию") || return
        case $c in
            install)   web_install ;;
            list)      ui_msg "$(list_published)" ;;
            publish)   web_publish ;;
            unpublish) web_unpublish ;;
        esac
    done
}

# ──────────────────── Базовая настройка сервера (ОС) ────────────────
base_setup_os() {
    local TZ_DEFAULT="Asia/Yekaterinburg" DEF_LOCALE="ru_RU.UTF-8"
    ui_yesno "Выполнить базовую настройку ОС?\n\n• apt update/upgrade\n• пакеты: mc nano console-setup net-tools htop locales tzdata\n• локали ru_RU.UTF-8 + en_US.UTF-8\n• часовой пояс $TZ_DEFAULT\n• console-setup (UTF-8, TerminusBold 8x16)" || return

    run_cmd "apt-get update -y && apt-get upgrade -y" "Обновление системы"
    run_cmd "DEBIAN_FRONTEND=noninteractive apt-get install -y lsb-release mc nano console-setup net-tools htop locales tzdata" "Установка базовых пакетов"

    # Локали — идемпотентно (раскомментировать существующие или добавить)
    sed -i 's/^# *\(ru_RU.UTF-8 UTF-8\)/\1/; s/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen 2>/dev/null
    grep -qxF "ru_RU.UTF-8 UTF-8" /etc/locale.gen 2>/dev/null || echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen
    grep -qxF "en_US.UTF-8 UTF-8" /etc/locale.gen 2>/dev/null || echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
    run_cmd "locale-gen" "Генерация локалей"
    run_cmd "update-locale LANG=$DEF_LOCALE LC_ALL=$DEF_LOCALE" "Локаль по умолчанию $DEF_LOCALE"
    # применяем локаль и в текущей сессии скрипта
    export LANG="$DEF_LOCALE" LC_ALL="$DEF_LOCALE" LANGUAGE="ru_RU:ru"

    # Часовой пояс (с запасным путём для LXC без timedated)
    if command -v timedatectl >/dev/null 2>&1 && timedatectl set-timezone "$TZ_DEFAULT" 2>/dev/null; then
        :
    else
        ln -sf "/usr/share/zoneinfo/$TZ_DEFAULT" /etc/localtime
        echo "$TZ_DEFAULT" > /etc/timezone
        dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1 || true
    fi

    # Консоль — без диалогов (Способ 1)
    cat > /etc/default/console-setup <<'EOF'
ACTIVE_CONSOLES="/dev/tty[1-6]"
CHARMAP="UTF-8"
CODESET="guess"
FONTFACE="TerminusBold"
FONTSIZE="8x16"
EOF
    setupcon --force >/dev/null 2>&1 || true

    ui_msg "Базовая настройка завершена.\n\nДата/время: $(date '+%F %T %Z')\nЛокаль по умолчанию: $DEF_LOCALE\n\nДля применения локали в текущей сессии выполните:\n  source /etc/default/locale"
}

# ───────────────────────────── Главное меню ─────────────────────────
main() {
    while true; do
        CANCEL_LABEL="Выход"
        local c; c=$(ui_menu "Менеджер сервера 1С:Предприятие" "Выберите действие" \
            setup_os  "Базовая настройка сервера (ОС)" \
            install   "Установить платформу" \
            upgrade   "Обновить платформу" \
            delete    "Удалить платформу" \
            instances "Экземпляры (рабочие серверы)" \
            debug     "Отладка экземпляров" \
            web       "Веб-модуль и публикация баз" \
            versions  "Список установленных версий") || { echo "Выход"; exit 0; }
        CANCEL_LABEL="Назад"
        case $c in
            setup_os)  base_setup_os ;;
            install)   menu_install ;;
            upgrade)   menu_upgrade ;;
            delete)    menu_delete ;;
            instances) menu_instances ;;
            debug)     menu_debug ;;
            web)       menu_web ;;
            versions)
                local list; list=$(discover_installed_versions)
                ui_msg "Установленные версии:\n${list:-нет}" ;;
        esac
    done
}

# Запуск меню только при прямом вызове; при `source` (для тестов) — функции доступны без меню
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
