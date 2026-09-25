# ru-gov-dns-forward.rsc
#
# Условная пересылка DNS-запросов российских госсайтов на резолвер внутри РФ.
# Требуется RouterOS 7.17+ (в ней появился /ip/dns/forwarders).
# Для более старых версий используйте ru-gov-dns-forward-legacy.rsc.
#
# Установка:
#   /file print                      # убедиться, что файл загружен
#   /import file-name=ru-gov-dns-forward.rsc
#
# Скрипт идемпотентный: повторный запуск пересоздаёт свои записи
# и не трогает чужие статические записи DNS.

:local fwdName     "yandex"
:local dnsServers  "77.88.8.8,77.88.8.1"
:local tag         "ru-gov-dns"
:local addrList    "RU-GOV"
# addrList="" отключает наполнение firewall address-list

:local domains {
    "gosuslugi.ru";
    "xn--c1aapkosapc.xn--p1ai";
    "gov.ru";
    "nalog.ru";
    "cdn.ngenix.net";
    "zakupki.gov.ru";
    "roseltorg.ru";
    "sberbank-ast.ru";
    "rts-tender.ru";
    "tektorg.ru";
    "zakazrf.ru";
    "etp-ets.ru"
}

:put "[ru-gov-dns] RouterOS $[/system/resource/get version]"

# --- forwarder ---------------------------------------------------------------

:if ([:len [/ip/dns/forwarders/find name=$fwdName]] = 0) do={
    /ip/dns/forwarders/add name=$fwdName dns-servers=$dnsServers
    :put "[ru-gov-dns] forwarder '$fwdName' создан: $dnsServers"
} else={
    /ip/dns/forwarders/set [/ip/dns/forwarders/find name=$fwdName] dns-servers=$dnsServers
    :put "[ru-gov-dns] forwarder '$fwdName' обновлён: $dnsServers"
}

# --- очистка своих прошлых записей -------------------------------------------

:local old [:len [/ip/dns/static/find where comment~$tag]]
:if ($old > 0) do={
    /ip/dns/static/remove [/ip/dns/static/find where comment~$tag]
    :put "[ru-gov-dns] удалено прошлых записей: $old"
}

# --- статические FWD-записи --------------------------------------------------

:local added 0
:foreach d in=$domains do={
    :local c ($tag . ": " . $d)
    :do {
        :if ([:len $addrList] > 0) do={
            /ip/dns/static/add name=$d type=FWD forward-to=$fwdName \
                match-subdomain=yes address-list=$addrList comment=$c
        } else={
            /ip/dns/static/add name=$d type=FWD forward-to=$fwdName \
                match-subdomain=yes comment=$c
        }
        :set added ($added + 1)
    } on-error={
        :put "[ru-gov-dns] ОШИБКА при добавлении $d"
    }
}
:put "[ru-gov-dns] добавлено записей: $added"

# --- финал -------------------------------------------------------------------

/ip/dns/cache/flush
:put "[ru-gov-dns] кэш DNS очищен"
:put "[ru-gov-dns] готово. Проверка: /ip/dns/static/print where type=FWD"
