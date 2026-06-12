# Telegram IP Address List Updater (IPv4 only)
# Работает на RouterOS 6.43+ и 7.x
# Скачивает актуальный список IPv4-сетей Telegram и обновляет address-list.
#
# Установка:
# /system script add name=telegram-ip-updater source={ ... код ... }
# /system script run telegram-ip-updater
#
# Автозапуск:
# /system scheduler add name=telegram-update interval=1d \
#     start-time=03:30:00 on-event="/system script run telegram-ip-updater"

:local url "https://core.telegram.org/resources/cidr.txt"
:local listName "TG"

# --- 1. Скачиваем список прямо в переменную (без временного файла) ---
# output=user as-value отдаёт тело ответа в массив, минуя файловую систему:
# это убирает создание/удаление файла, ожидание загрузки и проверки файла.
:local content ""
:do {
    # check-certificate=no — список публичный, а на роутере может не быть
    # импортированного CA-хранилища, из-за чего HTTPS-fetch падает на TLS.
    :local result [/tool fetch url=$url check-certificate=no output=user as-value]
    :if (($result->"status") = "finished") do={
        :set content ($result->"data")
    }
} on-error={
    :log error "Telegram IP updater: Fetch failed (check DNS / internet / TLS)"
    :error "Fetch failed"
}

# --- 2. Проверяем, что что-то скачалось ---
:local size [:len $content]
:if ($size = 0) do={
    :log error "Telegram IP updater: Empty response"
    :error "Empty response"
}
:log info "Telegram IP updater: Downloaded successfully ($size bytes)"

# --- 3. Разбираем ответ во временный набор адресов ---
# Сначала собираем валидные IPv4-сети в массив и только потом меняем
# боевой address-list — так список не остаётся пустым во время обновления.
:local newList [:toarray ""]
:local skipped 0
:local start 0
:local len $size

:while ($start < $len) do={
    :local pos [:find $content "\n" $start]
    :if ([:typeof $pos] = "nil") do={ :set pos $len }

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

# --- 4. Обновляем address-list только при наличии валидных записей ---
:if ([:len $newList] = 0) do={
    :log warning "Telegram IP updater: No valid IPv4 entries found! (skipped $skipped entries)"
    :error "No valid entries"
}

:local oldCount [:len [/ip firewall address-list find list=$listName]]
:if ($oldCount > 0) do={
    /ip firewall address-list remove [find list=$listName]
    :log info "Telegram IP updater: Removed $oldCount old entries from '$listName'"
}

:local count 0
:foreach ip in=$newList do={
    :do {
        /ip firewall address-list add list=$listName address=$ip comment="Telegram IPv4"
        :set count ($count + 1)
    } on-error={
        :set skipped ($skipped + 1)
        :log warning "Telegram IP updater: Skipped invalid IPv4 entry: '$ip'"
    }
}

# --- 5. Финальный лог ---
:log info "Telegram IP updater: Added $count IPv4 entries to '$listName' (skipped $skipped non-IPv4/invalid entries)"
