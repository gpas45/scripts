# IP Updater — address-list "ip-updater" (IPv4 only)
# Работает на RouterOS 6.43+ и 7.x
# Резолвит хосты-источники списков адресов (goog.json, Telegram, CloudFlare,
# GitHub raw) и складывает полученные IP в address-list "ip-updater".
#
# Зачем: сами источники из РФ часто недоступны напрямую. Список "ip-updater"
# используется в mangle-правилах цепочки output, которые заворачивают
# исходящий трафик самого роутера в туннель — иначе /tool fetch в
# ip-lists-updater.rsc не дойдёт до сервера. См. docs/ip-lists-updater.md.
#
# Запускать ПЕРЕД ip-lists-updater (например, на 5 минут раньше).
#
# Записи только добавляются: прошлые IP остаются, чтобы неудачный резолв
# не оставил mangle-правило без адресов. Ручная чистка списка:
# /ip firewall address-list remove [find list=ip-updater comment~"^ip-updater:"]
#
# Установка:
# /import file-name=ip-updater.rsc
# /system script
# add name=ip-updater policy=read,write,test source=[/file get ip-updater.rsc contents]
# /system script run ip-updater
#
# Автозапуск:
# /system scheduler
# add name=ip-updater interval=1d start-time=03:25:00 \
#    on-event="/system script run ip-updater" \
#    policy=read,write,test

# --- 0. Настройки ---
:local listName "ip-updater"
:local cmntPrefix "ip-updater:"

# DNS-сервер для резолва. "" — брать настройки роутера (/ip dns).
# Полезно указать явно, если провайдерский DNS подменяет ответы.
:local dnsServer ""

# Сколько раз резолвить каждый хост за прогон: у CDN несколько A-записей,
# round-robin отдаёт их по очереди, так список постепенно становится полнее.
:local tries 3

# Хосты-источники. Соответствуют URL в ip-lists-updater.rsc.
:local hosts {"www.gstatic.com";"core.telegram.org";"www.cloudflare.com";"raw.githubusercontent.com"}

:local hostCount [:len $hosts]
:local added 0
:local failed 0

# --- 1. Резолвим хосты и дополняем address-list ---
:foreach host in=$hosts do={
    :local got 0

    :for i from=1 to=$tries do={
        :local addr ""
        :do {
            :if ([:len $dnsServer] > 0) do={
                :set addr [:resolve $host server=$dnsServer]
            } else={
                :set addr [:resolve $host]
            }
        } on-error={
            # Нет DNS / NXDOMAIN / таймаут — просто пробуем следующий заход.
            :set addr ""
        }

        :if ([:typeof $addr] = "ip") do={
            :set got ($got + 1)
            :local ipStr [:tostr $addr]
            # Дубли не плодим: проверяем боевой список перед добавлением.
            :if ([:len [/ip firewall address-list find list=$listName address=$ipStr]] = 0) do={
                :do {
                    /ip firewall address-list add list=$listName address=$ipStr comment="$cmntPrefix $host"
                    :set added ($added + 1)
                    :log info "IP updater: added $ipStr ($host) to '$listName'"
                } on-error={
                    :log warning "IP updater: failed to add $ipStr ($host)"
                }
            }
        }
    }

    :if ($got = 0) do={
        :set failed ($failed + 1)
        :log warning "IP updater: resolve failed for $host (check /ip dns)"
    }
}

# --- 2. Финальный лог ---
:local total [:len [/ip firewall address-list find list=$listName]]
:if ($failed > 0) do={
    :log warning "IP updater: $failed of $hostCount hosts not resolved"
}
:log info "IP updater: added $added new entries, '$listName' now has $total entries"
:put ("Done! Added: $added new entries, '$listName' total: $total (failed hosts: $failed)")
