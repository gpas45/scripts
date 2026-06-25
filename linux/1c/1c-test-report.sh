#!/bin/bash
#
# 1c-test-report.sh — автоматическая проверка 1c-server-manager.sh и сбор состояния системы.
# Запускать от root В ТОМ ЖЕ каталоге, где лежит 1c-server-manager.sh.
#
#   sudo ./1c-test-report.sh > otchet.txt 2>&1
#
# Затем пришлите файл otchet.txt.
#
MAIN="./1c-server-manager.sh"
SEP() { echo; echo "===================== $* ====================="; }

[[ $EUID -ne 0 ]] && { echo "Запустите от root"; exit 1; }
[[ -f "$MAIN" ]] || { echo "Не найден $MAIN рядом с этим скриптом"; exit 1; }

echo "ОТЧЁТ 1c-server-manager :: $(date '+%F %T')"
echo "Хост: $(hostname)  |  $(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME")  |  arch: $(dpkg --print-architecture 2>/dev/null || uname -m)"

SEP "1. Синтаксис скрипта (bash -n)"
if bash -n "$MAIN"; then echo "OK: синтаксических ошибок нет"; else echo "ОШИБКА синтаксиса"; fi

SEP "2. Подключение функций (source без запуска меню)"
# Гард в main-скрипте не даёт запуститься меню при source.
if source "$MAIN"; then echo "OK: функции подключены"; else echo "ОШИБКА source (код $?)"; fi
DIALOG=""   # форсируем неинтерактивный режим для инспекции

SEP "3. Юнит-тесты: проверка формата версии"
for v in 8.3.24.1500 8.3.4.100 8.2.19.1234 abc; do
    if is_valid_version "$v"; then echo "  $v -> валидна"; else echo "  $v -> отклонена"; fi
done

SEP "4. Юнит-тесты: поддержка версии (>= $MIN_VERSION) и выбор компонентов"
for v in 8.3.20.100 8.3.21.1000 8.3.23.1782 8.3.24.1500 8.3.27.1000; do
    sup=no;  version_supported "$v" && sup=yes
    deps=no; { version_supported "$v" && [[ "$(printf '%s\n8.3.24\n' "$v" | sort -V | head -n1)" == "8.3.24" ]]; } && deps=yes
    ench=no; [[ "$(printf '%s\n8.3.24\n' "$v" | sort -V | head -n1)" == "$v" && "$v" != "8.3.24"* ]] && ench=yes
    echo "  $v -> поддержка=$sup, v8_install_deps=$deps, libenchant=$ench"
done

SEP "5. Дистрибутивы в каталоге, доступные для установки"
discover_install_versions | sort -uV | sed 's/^/  /' || true

SEP "6. Установленные версии платформы"
discover_installed_versions | sed 's/^/  /' || echo "  нет"

SEP "7. Экземпляры (рабочие серверы)"
mapfile -t INST < <(discover_instances)
if (( ${#INST[@]} == 0 )); then
    echo "  экземпляров не найдено"
else
    for u in "${INST[@]}"; do
        ver=$(echo "$u" | grep -oP 'srv1cv8-\K[0-9.]+(?=@)'); nm=${u##*@}
        st=$(systemctl is-active "$u" 2>/dev/null)
        port=$(systemctl show "$u" -p Environment --no-pager 2>/dev/null | grep -oP 'SRV1CV8_PORT=\K[0-9]+')
        dbg=$(get_debug_state "$ver" "$nm")
        echo "  $u :: статус=$st, порт=${port:-1540(default)}, отладка=$dbg"
    done
fi

SEP "8. Содержимое override.conf всех экземпляров"
for f in /etc/systemd/system/srv1cv8-*@*.service.d/override.conf; do
    [[ -f "$f" ]] || continue
    echo "--- $f"; cat "$f"; echo
done

SEP "9. systemd: юниты 1С"
systemctl list-units 'srv1cv8-*' --all --no-pager 2>/dev/null | sed 's/^/  /'

SEP "10. Занятые порты 1С (15xx/25xx)"
ss -tulpn 2>/dev/null | grep -E ':1(54[0-9]|5[6-9][0-9])|:2(54[0-9]|5[5-9][0-9])' | sed 's/^/  /' || echo "  нет"

SEP "11. Веб-модуль / Apache"
if command -v apache2ctl >/dev/null; then
    echo "  MPM: $(apache2ctl -M 2>/dev/null | grep mpm_ | awk '{print $1}' | tr '\n' ' ')"
    echo "  ws-библиотеки:"; ls /opt/1cv8/x86_64/*/ws/apache2.4/ 2>/dev/null | sed 's/^/    /' || echo "    нет"
    echo "  публикации в /var/www:"; ls -1 /var/www 2>/dev/null | sed 's/^/    /'
    echo "  записи о публикациях в apache2.conf:"; grep -iE 'Directory|1cws|webinst' /etc/apache2/apache2.conf 2>/dev/null | sed 's/^/    /' || echo "    нет"
else
    echo "  Apache не установлен"
fi

SEP "12. Пользователь/группа 1С"
id usr1cv8 2>/dev/null || echo "  usr1cv8 отсутствует"

SEP "13. Хвост лога установки (1c-server-manager.log)"
[[ -f 1c-server-manager.log ]] && tail -40 1c-server-manager.log || echo "  лог не найден (установка ещё не запускалась)"

SEP "КОНЕЦ ОТЧЁТА"
