# Google IP Address List Updater (IPv4 only)
# Работает на RouterOS 6.43+ и 7.x
# Скачивает официальный список IP-диапазонов Google (goog.json) и обновляет
# address-list. Удобно для policy-routing/VPN на сервисы Google (включая YouTube).
#
# Источник: https://www.gstatic.com/ipranges/goog.json
# Внимание: goog.json содержит ВСЕ публичные диапазоны Google, а не только YouTube.
#
# Установка:
# /import file-name=google-ip-updater.rsc
# /system script
# add name=google-ip-updater policy=read,write,test source=[/file get google-ip-updater.rsc contents]
# /system script run google-ip-updater
#
# Автозапуск:
# /system scheduler
# add name=google-update interval=7d start-time=03:41:00 \
#    on-event="/system script run google-ip-updater" \
#    policy=read,write,test

:local url "https://www.gstatic.com/ipranges/goog.json"
:local listName "VPN_ytb"
:local cmnt "google-auto"

# --- 1. Скачиваем список прямо в переменную (без временного файла) ---
# output=user as-value отдаёт тело ответа в массив, минуя файловую систему.
:local content ""
:do {
    # check-certificate=no — список публичный, а на роутере может не быть
    # импортированного CA-хранилища, из-за чего HTTPS-fetch падает на TLS.
    :local result [/tool fetch url=$url check-certificate=no output=user as-value]
    :if (($result->"status") = "finished") do={
        :set content ($result->"data")
    }
} on-error={
    :log error "Google IP updater: Fetch failed (check DNS / internet / TLS)"
    :error "Fetch failed"
}

# --- 2. Проверяем, что что-то скачалось ---
:local size [:len $content]
:if ($size = 0) do={
    :log error "Google IP updater: Empty response"
    :error "Empty response"
}
:log info "Google IP updater: Downloaded successfully ($size bytes)"

# --- 3. Разбираем JSON во временный набор адресов ---
# Сначала собираем валидные IPv4-сети в массив и только потом меняем
# боевой address-list — так список не остаётся пустым во время обновления.
# Формат goog.json: { "prefixes": [ { "ipv4Prefix": "8.8.4.0/24" }, ... ] }
:local newList [:toarray ""]
:local startTag "\"ipv4Prefix\": \""
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

# --- 4. Обновляем address-list только при наличии валидных записей ---
:if ([:len $newList] = 0) do={
    :log warning "Google IP updater: No valid IPv4 prefixes found!"
    :error "No valid entries"
}

:local oldCount [:len [/ip firewall address-list find list=$listName comment=$cmnt]]
:if ($oldCount > 0) do={
    /ip firewall address-list remove [find list=$listName comment=$cmnt]
    :log info "Google IP updater: Removed $oldCount old entries from '$listName'"
}

:local count 0
:local skipped 0
:foreach ip in=$newList do={
    :do {
        /ip firewall address-list add list=$listName address=$ip comment=$cmnt
        :set count ($count + 1)
    } on-error={
        :set skipped ($skipped + 1)
        :log warning "Google IP updater: Skipped invalid entry: '$ip'"
    }
}

# --- 5. Финальный лог ---
:log info "Google IP updater: Added $count IPv4 prefixes to '$listName' (skipped $skipped invalid)"
:put ("Done! Added: $count subnets to '$listName' (skipped $skipped)")
