#!/bin/bash
# php2shell-check.sh — проверка Synology DSM на уязвимость PHP2Shell
#   CVE-2026-109618, CVE-2026-109619 — RCE в PHP, CVSS v4.0 9.2, раскрыты 21.10.2026.
#
# Что делает:
#   1. находит установленные пакеты PHP (Package Center);
#   2. сравнивает версию каждого с версией, в которой уязвимость исправлена;
#   3. проверяет session.upload_progress.enabled — подтверждённый путь эксплуатации;
#   4. оценивает экспозицию: установлен ли и запущен Web Station, работают ли php-fpm.
#
# Запуск:  sudo ./php2shell-check.sh
#   Без root часть конфигов PHP недоступна для чтения — проверка п.3 будет неполной.
#
# Коды возврата:
#   0 — уязвимых пакетов PHP не найдено;
#   1 — найден уязвимый пакет PHP;
#   2 — ошибка запуска (не Synology DSM).
#
# set -e намеренно не включён: проверки штатно возвращают ненулевой код возврата.
set -uo pipefail

# Версии, в которых PHP2Shell исправлен (релизы PHP от 21.10.2026).
# Ветки 8.1 и старше официального исправления не получили — только бэкпорты исходников.
FIXED_8_2=35
FIXED_8_3=36
FIXED_8_4=27
FIXED_8_5=12

VULN_COUNT=0
UNKNOWN_COUNT=0
PHP_FOUND=0
USAGE_FOUND=0
PHP_PKG_LIST=''

# Цвета только для интерактивного терминала
if [ -t 1 ]; then
    C_RED=$'\033[1;31m'
    C_YELLOW=$'\033[1;33m'
    C_GREEN=$'\033[1;32m'
    C_BOLD=$'\033[1m'
    C_OFF=$'\033[0m'
else
    C_RED=''
    C_YELLOW=''
    C_GREEN=''
    C_BOLD=''
    C_OFF=''
fi

# Заголовок раздела
header() {
    printf '\n%s=== %s ===%s\n' "$C_BOLD" "$1" "$C_OFF"
}

# Чтение key=value из файла DSM: read_keyvalue <файл> <ключ>
# Предпочитает штатный synogetkeyvalue, иначе разбирает файл сам.
read_keyvalue() {
    local file=$1 key=$2 value=''
    if [ -x /usr/syno/bin/synogetkeyvalue ]; then
        value=$(/usr/syno/bin/synogetkeyvalue "$file" "$key" 2>/dev/null)
    fi
    if [ -z "$value" ] && [ -r "$file" ]; then
        value=$(grep -m1 "^${key}=" "$file" 2>/dev/null | cut -d= -f2- | tr -d '"')
    fi
    echo "$value"
}

# Проверка, что это Synology DSM
check_platform() {
    if [ ! -f /etc.defaults/VERSION ]; then
        printf '%sОшибка: это не Synology DSM (нет /etc.defaults/VERSION).%s\n' "$C_RED" "$C_OFF" >&2
        exit 2
    fi

    local model dsm_ver dsm_build
    model=$(read_keyvalue /etc.defaults/synoinfo.conf upnpmodelname)
    dsm_ver=$(read_keyvalue /etc.defaults/VERSION productversion)
    dsm_build=$(read_keyvalue /etc.defaults/VERSION buildnumber)

    printf 'Модель: %s\n' "${model:-неизвестно}"
    printf 'DSM:    %s (сборка %s)\n' "${dsm_ver:-неизвестно}" "${dsm_build:-?}"

    if [ "$(id -u)" -ne 0 ]; then
        printf '%sВнимание: запуск не от root — часть конфигов PHP прочитать не удастся.%s\n' \
            "$C_YELLOW" "$C_OFF"
    fi
}

# Чтение поля из файла INFO пакета: get_info_field <файл> <поле>
get_info_field() {
    local file=$1 field=$2
    grep -m1 "^${field}=" "$file" 2>/dev/null | cut -d= -f2- | tr -d '"'
}

# Исправленный патч-уровень для ветки PHP: fixed_patch_for 8.2 -> 35
# Пустой вывод означает, что официального исправления для ветки нет.
fixed_patch_for() {
    case "$1" in
        8.2) echo "$FIXED_8_2" ;;
        8.3) echo "$FIXED_8_3" ;;
        8.4) echo "$FIXED_8_4" ;;
        8.5) echo "$FIXED_8_5" ;;
        *)   echo "" ;;
    esac
}

# Статус пакета в DSM: running / stopped / неизвестно
# DSM 7.4+ отдаёт JSON, более ранние версии — одно слово; разбираем оба случая.
package_status() {
    local pkg=$1 raw='' status=''
    if [ -x /usr/syno/bin/synopkg ]; then
        raw=$(/usr/syno/bin/synopkg status "$pkg" 2>/dev/null)
    fi
    case "$raw" in
        '{'*)
            # {"aspect":{"active":{"status":"running"},...,"status":"running"}}
            # Берём последнее поле — статус самого пакета, а не вложенного аспекта.
            status=$(echo "$raw" | grep -o '"status":"[^"]*"' | tail -1 | cut -d'"' -f4)
            ;;
        *)
            status=$(echo "$raw" | tr -d '[:space:]')
            ;;
    esac
    echo "${status:-неизвестно}"
}

# Вердикт по одному пакету PHP: verdict <пакет> <версия>
verdict() {
    local pkg=$1 version=$2
    local upstream branch patch fixed status

    # "8.2.30-0170" -> upstream "8.2.30", build "0170"
    upstream=${version%%-*}
    branch=$(echo "$upstream" | cut -d. -f1,2)
    patch=$(echo "$upstream" | cut -d. -f3)
    patch=${patch:-0}
    fixed=$(fixed_patch_for "$branch")
    status=$(package_status "$pkg")

    printf '\n%s%s%s — версия пакета %s (PHP %s), состояние: %s\n' \
        "$C_BOLD" "$pkg" "$C_OFF" "$version" "$upstream" "$status"

    if [ -z "$fixed" ]; then
        printf '  %sУЯЗВИМ%s — ветка PHP %s официального исправления PHP2Shell не получила.\n' \
            "$C_RED" "$C_OFF" "$branch"
        printf '  Ветка снята с поддержки. Нужен переход на PHP 8.2.%s или новее.\n' "$FIXED_8_2"
        VULN_COUNT=$((VULN_COUNT + 1))
        return
    fi

    # Нечисловой патч-уровень сравнить нельзя. Молчать здесь недопустимо:
    # иначе уязвимый пакет был бы показан как исправный.
    case "$patch" in
        *[!0-9]*)
            printf '  %sНЕ ОПРЕДЕЛЕНО%s — не удалось разобрать версию "%s".\n' \
                "$C_YELLOW" "$C_OFF" "$version"
            printf '  Сравните вручную с PHP %s.%s.\n' "$branch" "$fixed"
            UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1))
            return
            ;;
    esac

    if [ "$patch" -lt "$fixed" ]; then
        printf '  %sУЯЗВИМ%s — PHP2Shell исправлен в %s.%s, установлено %s.\n' \
            "$C_RED" "$C_OFF" "$branch" "$fixed" "$upstream"
        printf '  Обновите пакет в Package Center до сборки с PHP %s.%s или новее.\n' \
            "$branch" "$fixed"
        VULN_COUNT=$((VULN_COUNT + 1))
    else
        printf '  %sОК%s — %s >= %s.%s, PHP2Shell исправлен.\n' \
            "$C_GREEN" "$C_OFF" "$upstream" "$branch" "$fixed"
    fi
}

# Перечисление установленных пакетов PHP
check_php_packages() {
    header "Пакеты PHP"

    local info pkg version
    for info in /var/packages/*/INFO; do
        [ -f "$info" ] || continue
        pkg=$(get_info_field "$info" package)
        case "$pkg" in
            PHP*) ;;
            *) continue ;;
        esac
        version=$(get_info_field "$info" version)
        [ -n "$version" ] || continue
        PHP_FOUND=$((PHP_FOUND + 1))
        PHP_PKG_LIST="${PHP_PKG_LIST}${pkg}
"
        verdict "$pkg" "$version"
    done

    if [ "$PHP_FOUND" -eq 0 ]; then
        printf '%sПакеты PHP не установлены — PHP2Shell не применим.%s\n' "$C_GREEN" "$C_OFF"
    fi
}

# Кто на NAS использует PHP: зависимости пакетов, задачи cron, Web Station.
# Нужно, чтобы понять, можно ли удалить пакет вместо ожидания патча.
#
# Проверка намеренно осторожна: Web Station назначает PHP-профили сайтам
# через свой интерфейс, и надёжно прочитать это из файлов нельзя. Поэтому
# «ничего не найдено» формулируется как предположение, а не как разрешение
# удалять — ложный вывод здесь стоит дороже лишней проверки руками.
check_php_usage() {
    header "Кто использует PHP"

    if [ "$PHP_FOUND" -eq 0 ]; then
        printf 'Пропущено: пакеты PHP не установлены.\n'
        return
    fi

    local php_pkg info dep_pkg deps users cron_hits

    # 1. Пакеты, объявившие PHP зависимостью в своём INFO
    while IFS= read -r php_pkg; do
        [ -n "$php_pkg" ] || continue
        users=''
        for info in /var/packages/*/INFO; do
            [ -f "$info" ] || continue
            dep_pkg=$(get_info_field "$info" package)
            [ -n "$dep_pkg" ] || continue
            [ "$dep_pkg" = "$php_pkg" ] && continue
            deps="$(get_info_field "$info" install_dep_packages) "
            deps="${deps}$(get_info_field "$info" start_dep_services)"
            case "$deps" in
                *"$php_pkg"*) users="${users}${users:+, }${dep_pkg}" ;;
            esac
        done
        if [ -n "$users" ]; then
            printf '%s — объявлен зависимостью пакетов: %s\n' "$php_pkg" "$users"
            USAGE_FOUND=1
        else
            printf '%s — ни один пакет не объявил его зависимостью\n' "$php_pkg"
        fi
    done <<< "$PHP_PKG_LIST"

    # 2. Задачи планировщика, вызывающие php
    if [ -r /etc/crontab ]; then
        cron_hits=$(grep -c 'php' /etc/crontab 2>/dev/null)
        cron_hits=${cron_hits:-0}
        if [ "$cron_hits" -gt 0 ]; then
            printf '\nСтрок с "php" в /etc/crontab: %s\n' "$cron_hits"
            grep -n 'php' /etc/crontab 2>/dev/null | cut -c1-100 | sed 's/^/  /'
            printf 'Проверьте глазами: совпадение по имени ещё не значит запуск PHP.\n'
            USAGE_FOUND=1
        else
            printf '\nВ /etc/crontab задач с php нет.\n'
        fi
    else
        printf '\n/etc/crontab недоступен — задачи планировщика не проверены.\n'
    fi

    # 3. Web Station раздаёт PHP сайтам через профили — только ручная проверка
    if [ -f /var/packages/WebStation/INFO ]; then
        printf '\n%sУстановлен Web Station%s — сайты могут использовать PHP через профили.\n' \
            "$C_YELLOW" "$C_OFF"
        printf 'Проверьте в интерфейсе: Web Station -> Веб-сервисы и Профили PHP.\n'
        USAGE_FOUND=1
    fi

    if [ "$USAGE_FOUND" -eq 0 ]; then
        printf '\n%sПризнаков использования PHP не найдено.%s\n' "$C_GREEN" "$C_OFF"
        printf 'Пакет, вероятно, можно удалить — это закрыло бы уязвимость полностью.\n'
        printf 'Перед удалением убедитесь, что PHP не нужен вашим собственным скриптам:\n'
        printf 'их вызовы эта проверка не видит.\n'
    fi
}

# Проверка session.upload_progress.enabled — путь эксплуатации CVE-2026-109619
check_upload_progress() {
    header "session.upload_progress.enabled"

    if [ "$PHP_FOUND" -eq 0 ]; then
        printf 'Пропущено: пакеты PHP не установлены.\n'
        return
    fi

    # find ... -exec grep: имена файлов не проходят через переменную,
    # поэтому пробелы в путях не ломают разбор.
    local ini_count hits found=0 web_found=0 line
    ini_count=$(find /usr/local/etc /etc/php* /var/packages/PHP*/target \
        -maxdepth 5 -name '*.ini' -type f 2>/dev/null | wc -l)

    if [ "$ini_count" -eq 0 ]; then
        printf '%sФайлы *.ini не найдены%s — проверьте настройку вручную в Web Station.\n' \
            "$C_YELLOW" "$C_OFF"
        return
    fi
    printf 'Просмотрено файлов *.ini: %s\n' "$ini_count"

    hits=$(find /usr/local/etc /etc/php* /var/packages/PHP*/target \
        -maxdepth 5 -name '*.ini' -type f \
        -exec grep -Hn '^[[:space:]]*session\.upload_progress\.enabled' {} + 2>/dev/null)

    # Путь атаки — только веб-SAPI (FPM). Интерпретатор CLI по сети недоступен,
    # поэтому его конфиги помечаем отдельно, чтобы не выдавать их за значимые.
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        found=1
        case "$line" in
            */cli/*)
                printf '  %s  %s[CLI — не сетевой путь атаки]%s\n' "$line" "$C_YELLOW" "$C_OFF"
                ;;
            *)
                web_found=1
                printf '  %s\n' "$line"
                ;;
        esac
    done <<< "$hits"

    if [ "$found" -eq 0 ]; then
        printf '  %sЯвно не задано — значит включено%s (значение PHP по умолчанию: On).\n' \
            "$C_YELLOW" "$C_OFF"
        printf '  Это оставляет открытым подтверждённый путь CVE-2026-109619.\n'
        return
    fi

    if [ "$web_found" -eq 0 ]; then
        printf '  Настройка найдена только в конфигах CLI — веб-профилей (FPM) с ней нет.\n'
        printf '  Для веб-SAPI действует значение по умолчанию (On).\n'
    fi
}

# Оценка экспозиции: нужен ли вообще PHP на этом NAS и доступен ли он
check_exposure() {
    header "Экспозиция"

    if [ "$PHP_FOUND" -eq 0 ]; then
        printf 'Пропущено: пакеты PHP не установлены.\n'
        return
    fi

    local ws_status fpm_count
    if [ -f /var/packages/WebStation/INFO ]; then
        ws_status=$(package_status WebStation)
        printf 'Web Station: установлен, состояние %s\n' "$ws_status"
    else
        printf 'Web Station: не установлен\n'
    fi

    if command -v pgrep >/dev/null 2>&1; then
        # -f обязателен: мастер FPM виден как «php-fpm: master process (...)»,
        # и по одному лишь имени процесса pgrep его не находит.
        fpm_count=$(pgrep -fc 'php-fpm' 2>/dev/null)
        fpm_count=${fpm_count:-0}
        printf 'Процессов php-fpm: %s\n' "$fpm_count"
        if [ "$fpm_count" -gt 0 ]; then
            printf '%sPHP реально обслуживает запросы — риск высокий, если сайт доступен извне.%s\n' \
                "$C_YELLOW" "$C_OFF"
        elif [ "$USAGE_FOUND" -eq 1 ]; then
            # Пакеты DSM поднимают свои пулы FPM по требованию, поэтому ноль
            # процессов в момент проверки не означает, что PHP недостижим.
            printf '%sПроцессов нет, но PHP используется пакетами DSM.%s\n' \
                "$C_YELLOW" "$C_OFF"
            printf 'Пулы FPM запускаются по требованию — не считайте это безопасным.\n'
        else
            printf 'PHP-FPM не запущен — поверхность атаки меньше, но пакет всё равно обновите.\n'
        fi
    else
        printf 'Процессов php-fpm: не удалось определить (в системе нет pgrep)\n'
    fi

    printf '\nПроверьте отдельно: опубликован ли Web Station в интернет\n'
    printf '(проброс портов на роутере, reverse proxy, QuickConnect).\n'
    printf 'Авторизация на уровне приложения PHP2Shell не блокирует —\n'
    printf 'PHP обрабатывает запрос раньше кода приложения.\n'
}

# Итог и рекомендации
summary() {
    header "Итог"

    if [ "$VULN_COUNT" -gt 0 ] || [ "$UNKNOWN_COUNT" -gt 0 ]; then
        if [ "$VULN_COUNT" -gt 0 ]; then
            printf '%sНайдено уязвимых пакетов PHP: %s%s\n' "$C_RED" "$VULN_COUNT" "$C_OFF"
        fi
        if [ "$UNKNOWN_COUNT" -gt 0 ]; then
            printf '%sПакетов с неразобранной версией (проверьте вручную): %s%s\n' \
                "$C_YELLOW" "$UNKNOWN_COUNT" "$C_OFF"
        fi
        printf '\nЧто делать:\n'
        printf '  1. Package Center -> обновить пакет PHP до сборки с исправленной версией\n'
        printf '     (PHP 8.2.%s / 8.3.%s / 8.4.%s / 8.5.%s или новее).\n' \
            "$FIXED_8_2" "$FIXED_8_3" "$FIXED_8_4" "$FIXED_8_5"
        printf '  2. Пока обновления нет — убрать Web Station из интернета\n'
        printf '     (закрыть порты, поставить перед ним WAF/reverse proxy).\n'
        printf '  3. Временно: session.upload_progress.enabled = Off в профиле PHP.\n'
        printf '     Закрывает подтверждённый путь CVE-2026-109619, но не CVE-2026-109618.\n'
        if [ "$USAGE_FOUND" -eq 0 ]; then
            printf '  4. Признаков использования PHP не найдено — удаление пакета\n'
            printf '     закрыло бы вопрос полностью, не дожидаясь патча.\n'
        else
            printf '  4. Если PHP ничем не используется — удалить пакет.\n'
        fi
        return 1
    fi

    printf '%sУязвимых пакетов PHP не найдено.%s\n' "$C_GREEN" "$C_OFF"
    return 0
}

main() {
    printf '%sПроверка Synology на PHP2Shell (CVE-2026-109618, CVE-2026-109619)%s\n' \
        "$C_BOLD" "$C_OFF"
    check_platform
    check_php_packages
    check_php_usage
    check_upload_progress
    check_exposure
    summary
}

main "$@"
