# ru-gov-dns-forward-legacy.rsc
#
# Вариант для RouterOS 7.x ниже 7.17, где нет /ip/dns/forwarders.
# forward-to принимает один IP-адрес, резервного сервера не будет.
#
# Установка:
#   /import file-name=ru-gov-dns-forward-legacy.rsc

:local dnsServer "77.88.8.8"
:local tag       "ru-gov-dns"

:local domains {
    "gosuslugi.ru";
    "xn--c1aapkosapc.xn--p1ai";
    "nalog.gov.ru";
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

:put "[ru-gov-dns] RouterOS $[/system/resource/get version] (legacy mode)"

:local old [:len [/ip/dns/static/find where comment~$tag]]
:if ($old > 0) do={
    /ip/dns/static/remove [/ip/dns/static/find where comment~$tag]
    :put "[ru-gov-dns] удалено прошлых записей: $old"
}

:local added 0
:foreach d in=$domains do={
    :do {
        /ip/dns/static/add name=$d type=FWD forward-to=$dnsServer \
            match-subdomain=yes comment=($tag . ": " . $d)
        :set added ($added + 1)
    } on-error={
        :put "[ru-gov-dns] ОШИБКА при добавлении $d"
    }
}
:put "[ru-gov-dns] добавлено записей: $added"

/ip/dns/cache/flush
:put "[ru-gov-dns] готово"
