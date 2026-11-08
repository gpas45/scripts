# IP Lists Updater — Google / Telegram / CloudFlare (IPv4 only)
# Работает на RouterOS 6.43+ и 7.x
# Один скрипт вместо трёх (google-ip-updater, telegram-ip-updater,
# cloudflare-ip-updater): скачивает официальные списки IPv4-сетей и наполняет
# ТРИ РАЗНЫХ address-list — имена и комментарии сохранены, как в отдельных
# скриптах, поэтому firewall-правила менять не нужно:
#
#   Google (goog.json)   -> VPN_ytb   comment=google-auto
#   Telegram (cidr.txt)  -> TG        comment="Telegram IPv4"
#   CloudFlare (ips-v4)  -> CF        comment="cloudflare IPv4"
#
# Чистит только свои записи (по list + comment), чужие в этих списках не трогает.
# Если источник не ответил или ответ пустой — старый список остаётся как был,
# а остальные источники всё равно обновляются.
#
# ВАЖНО: источники из РФ часто недоступны напрямую. Перед этим скриптом
# запускайте ip-updater.rsc и заворачивайте исходящий трафик роутера к
# address-list "ip-updater" в туннель mangle-правилами — см.
# docs/ip-lists-updater.md, раздел «Маркировка исходящих пакетов».
#
# Установка:
# /import file-name=ip-lists-updater.rsc
# /system script
# add name=ip-lists-updater policy=read,write,test source=[/file get ip-lists-updater.rsc contents]
# /system script run ip-lists-updater
#
# Автозапуск:
# /system scheduler
# add name=ip-lists-update interval=1d start-time=03:30:00 \
#    on-event="/system script run ip-lists-updater" \
#    policy=read,write,test

# --- 1. Общая функция обновления одного списка ---
# Параметры: label, url, listName, cmnt, format ("json" | "txt")
# Возвращает число добавленных записей (0 — если обновить не удалось).
:local updateList do={
    # --- 1.1 Скачиваем список прямо в переменную (без временного файла) ---
    # output=user as-value отдаёт тело ответа в массив, минуя файловую систему.
    :local content ""
    :local ok true
    :do {
        # check-certificate=no — список публичный, а на роутере может не быть
        # импортированного CA-хранилища, из-за чего HTTPS-fetch падает на TLS.
        :local result [/tool fetch url=$url check-certificate=no output=user as-value]
        :if (($result->"status") = "finished") do={
            :set content ($result->"data")
        }
    } on-error={
        :set ok false
    }
    :if (!$ok) do={
        :log error "IP lists updater: $label - fetch failed (check DNS / internet / TLS / tunnel)"
        :return 0
    }

    # --- 1.2 Проверяем, что что-то скачалось ---
    :local size [:len $content]
    :if ($size = 0) do={
        :log error "IP lists updater: $label - empty response"
        :return 0
    }
    :log info "IP lists updater: $label - downloaded successfully ($size bytes)"

    # --- 1.3 Разбираем ответ во временный набор адресов ---
    # Сначала собираем валидные IPv4-сети в массив и только потом меняем
    # боевой address-list — так список не остаётся пустым во время обновления.
    :local newList [:toarray ""]
    :local skipped 0

    :if ($format = "json") do={
        # Формат goog.json: { "prefixes": [ { "ipv4Prefix": "8.8.4.0/24" }, ... ] }
        :local startTag "\"ipv4Prefix\": \""
        # Пробел после двоеточия Google может и не поставить — подстраиваемся.
        :if ([:typeof [:find $content $startTag 0]] = "nil") do={
            :set startTag "\"ipv4Prefix\":\""
        }
        :local tagLen [:len $startTag]
        :local pos 0

        :while ($pos < $size) do={
            :local findPos [:find $content $startTag $pos]
            :if ([:typeof $findPos] = "nil") do={
                # Больше префиксов нет — выходим из цикла.
                :set pos $size
            } else={
                :local start ($findPos + $tagLen)
                :local endPos [:find $content "\"" $start]
                :if ([:typeof $endPos] = "nil") do={
                    # Незакрытая кавычка (битый ответ) — прекращаем разбор.
                    :set pos $size
                } else={
                    :local subnet [:pick $content $start $endPos]
                    :if ([:len $subnet] > 0) do={ :set newList ($newList , $subnet) }
                    # Всегда двигаем позицию вперёд, чтобы не зациклиться.
                    :set pos ($endPos + 1)
                }
            }
        }
    } else={
        # Простой текст: по одной сети в строке.
        :local start 0

        :while ($start < $size) do={
            :local pos [:find $content "\n" $start]
            :if ([:typeof $pos] = "nil") do={ :set pos $size }

            :local line [:pick $content $start $pos]

            # Убираем \r (CRLF) и пробелы по краям
            :local crPos [:find $line "\r"]
            :if ([:typeof $crPos] != "nil") do={ :set line [:pick $line 0 $crPos] }
            :while ([:len $line] > 0 && [:pick $line 0 1] = " ") do={
                :set line [:pick $line 1 [:len $line]]
            }
            :while ([:len $line] > 0 && [:pick $line ([:len $line] - 1)] = " ") do={
                :set line [:pick $line 0 ([:len $line] - 1)]
            }

            # Пропускаем пустые строки, комментарии и IPv6 (содержат двоеточие)
            :if ([:len $line] > 0 && [:pick $line 0 1] != "#") do={
                :if ([:typeof [:find $line ":"]] = "nil") do={
                    :set newList ($newList , $line)
                } else={
                    :set skipped ($skipped + 1)
                }
            }
            :set start ($pos + 1)
        }
    }

    # --- 1.4 Обновляем address-list только при наличии валидных записей ---
    :if ([:len $newList] = 0) do={
        :log warning "IP lists updater: $label - no valid IPv4 entries found! (skipped $skipped)"
        :return 0
    }

    :local oldCount [:len [/ip firewall address-list find list=$listName comment=$cmnt]]
    :if ($oldCount > 0) do={
        /ip firewall address-list remove [find list=$listName comment=$cmnt]
        :log info "IP lists updater: $label - removed $oldCount old entries from '$listName'"
    }

    :local count 0
    :foreach ip in=$newList do={
        :do {
            /ip firewall address-list add list=$listName address=$ip comment=$cmnt
            :set count ($count + 1)
        } on-error={
            :set skipped ($skipped + 1)
            :log warning "IP lists updater: $label - skipped invalid entry: '$ip'"
        }
    }

    :log info "IP lists updater: $label - added $count IPv4 entries to '$listName' (skipped $skipped)"
    :return $count
}

# --- 2. Источники ---
# Правь URL и имена списков здесь. Имена address-list намеренно разные.
# Хосты этих URL должны быть в address-list "ip-updater" (см. ip-updater.rsc).
:local total 0

:do {
    :set total ($total + [$updateList label="Telegram" url="https://core.telegram.org/resources/cidr.txt" listName="TG" cmnt="Telegram IPv4" format="txt"])
} on-error={ :log error "IP lists updater: Telegram - unexpected script error" }

:do {
    :set total ($total + [$updateList label="CloudFlare" url="https://www.cloudflare.com/ips-v4/" listName="CF" cmnt="cloudflare IPv4" format="txt"])
} on-error={ :log error "IP lists updater: CloudFlare - unexpected script error" }

:do {
    :set total ($total + [$updateList label="Google" url="https://www.gstatic.com/ipranges/goog.json" listName="VPN_ytb" cmnt="google-auto" format="json"])
} on-error={ :log error "IP lists updater: Google - unexpected script error" }

# --- 3. Финальный лог ---
:local tgCount [:len [/ip firewall address-list find list="TG"]]
:local cfCount [:len [/ip firewall address-list find list="CF"]]
:local ytbCount [:len [/ip firewall address-list find list="VPN_ytb"]]
:log info "IP lists updater: finished, added $total entries (TG: $tgCount, CF: $cfCount, VPN_ytb: $ytbCount)"
:put ("Done! Added: $total entries (TG: $tgCount, CF: $cfCount, VPN_ytb: $ytbCount)")
