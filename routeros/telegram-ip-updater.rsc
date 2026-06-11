# Telegram IP Address List Updater (IPv4 only)
# Работает на RouterOS 6.x и 7.x
# Скачивает и обновляет список IPv4-адресов Telegram
# 
# Установка:
# /system script add name=telegram-ip-updater source={ ... код ... }
# /system script run telegram-ip-updater
#
# Автозапуск:
# /system scheduler add name=telegram-update interval=1d on-event=telegram-ip-updater start-time=03:30:00

:local url "https://core.telegram.org/resources/cidr.txt"
:local listName "TG"
:local tempFile "telegram-ips.txt"

# --- 1. Удаляем старый файл ---
:do {
    /file remove $tempFile
    :delay 1s
} on-error={}

:log info "Telegram IP updater: Downloading $url..."

# --- 2. Скачиваем файл ---
:do {
    /tool fetch url=$url dst-path=$tempFile
} on-error={
    :log error "Telegram IP updater: Fetch command failed"
    :error "Fetch failed"
}

# --- 3. Ждём завершения загрузки ---
:local maxWait 30
:local waited 0
:while ([:len [/file find name=$tempFile]] = 0 && $waited < $maxWait) do={
    :delay 1s
    :set waited ($waited + 1)
}

:if ($waited >= $maxWait) do={
    :log error "Telegram IP updater: Download timeout"
    :error "Download timeout"
}

:delay 2s

# --- 4. Проверка файла ---
:if ([:len [/file find name=$tempFile]] = 0) do={
    :log error "Telegram IP updater: File not found after download"
    :error "Download failed"
}

:local fileSize [/file get $tempFile size]
:if ($fileSize = 0) do={
    :log error "Telegram IP updater: Downloaded file is empty"
    /file remove $tempFile
    :error "Empty file"
}

:log info "Telegram IP updater: File downloaded successfully ($fileSize bytes)"

# --- 5. Очищаем старые записи ---
:local oldCount [:len [/ip firewall address-list find list=$listName]]
:if ($oldCount > 0) do={
    /ip firewall address-list remove [find list=$listName]
    :log info "Telegram IP updater: Removed $oldCount old entries from '$listName'"
}

# --- 6. Читаем файл и добавляем новые записи ---
:local content [/file get $tempFile contents]
:local start 0
:local len [:len $content]
:local count 0
:local skipped 0

:while ($start < $len) do={
    :local pos [:find $content "\n" $start]
    :if ([:typeof $pos] = "nil") do={
        :set pos $len
    }
    
    :local line [:pick $content $start $pos]
    
    # Убираем \r
    :local crPos [:find $line "\r"]
    :if ([:typeof $crPos] != "nil") do={
        :set line [:pick $line 0 $crPos]
    }
    
    # Убираем пробелы в начале
    :while ([:len $line] > 0 && [:pick $line 0 1] = " ") do={
        :set line [:pick $line 1 [:len $line]]
    }
    
    # Убираем пробелы в конце
    :while ([:len $line] > 0 && [:pick $line ([:len $line] - 1)] = " ") do={
        :set line [:pick $line 0 ([:len $line] - 1)]
    }
    
    # Пропускаем пустые строки и комментарии
    :if ([:len $line] > 0 && [:pick $line 0 1] != "#") do={
        # Простая проверка: если есть двоеточие - это IPv6, пропускаем
        :local colonPos [:find $line ":"]
        
        :if ([:typeof $colonPos] = "nil") do={
            # Нет двоеточия - пробуем добавить как IPv4
            :do {
                /ip firewall address-list add list=$listName address=$line comment="Telegram IPv4"
                :set count ($count + 1)
            } on-error={
                :set skipped ($skipped + 1)
                :log warning "Telegram IP updater: Skipped invalid IPv4 line: '$line'"
            }
        } else={
            :set skipped ($skipped + 1)
        }
    }
    :set start ($pos + 1)
}

# --- 7. Убираем временный файл ---
/file remove $tempFile

# --- 8. Финальный лог ---
:if ($count > 0) do={
    :log info "Telegram IP updater: Successfully added $count IPv4 entries to address list '$listName' (skipped $skipped IPv6 entries)"
} else={
    :log warning "Telegram IP updater: No valid IPv4 entries found! (skipped $skipped entries)"
}
