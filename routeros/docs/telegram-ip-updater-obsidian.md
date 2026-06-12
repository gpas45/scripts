---
title: Telegram IP Updater — установка на MikroTik
tags:
  - mikrotik
  - routeros
  - firewall
  - telegram
  - script
created: 2026-06-12
aliases:
  - telegram-ip-updater
  - TG address-list
---

# Telegram IP Updater — установка на MikroTik

Скрипт [[telegram-ip-updater]] (`routeros/telegram-ip-updater.rsc`) скачивает актуальный список IPv4-сетей Telegram и наполняет ими firewall `address-list` с именем **`TG`**.

> [!info] Назначение
> Список `TG` сам по себе ничего не блокирует и не разрешает — он используется в правилах firewall (например, разрешить/маркировать трафик к Telegram). Обновляется по расписанию, чтобы соответствовать официальным диапазонам Telegram (`https://core.telegram.org/resources/cidr.txt`).

> [!warning] Требования
> - **RouterOS 6.43+** или **7.x** (используется `/tool fetch ... as-value`).
> - Доступ роутера в интернет (HTTPS к `core.telegram.org`).
> - Права скрипта: `read,write,test`.

---

## Способ 1. Разовый запуск через `import`

> [!tip] Когда использовать
> Быстро проверить работу или наполнить список один раз, без автообновления.

### 1. Загрузить файл на роутер

Перетащить `telegram-ip-updater.rsc` в **Files** (Winbox/WebFig), или скачать прямо на роутер:

```routeros
/tool fetch url="https://raw.githubusercontent.com/gpas45/scripts/main/routeros/telegram-ip-updater.rsc"
```

### 2. Выполнить импорт

```routeros
/import file-name=telegram-ip-updater.rsc
```

После этого `address-list TG` наполнится сразу.

---

## Способ 2. System script + автозапуск (рекомендуется)

> [!tip] Когда использовать
> Постоянная установка с обновлением по расписанию.

### 1. Создать именованный скрипт

```routeros
/system script
add name=telegram-ip-updater policy=read,write,test \
    source=[/file get telegram-ip-updater.rsc contents]
```

> [!note]
> Альтернатива — вставить тело скрипта вручную в `source={ ... }`, если файл не загружали в Files.

### 2. Запустить вручную (проверка)

```routeros
/system script run telegram-ip-updater
```

### 3. Поставить на автообновление (раз в сутки)

```routeros
/system scheduler
add name=telegram-update interval=1d start-time=03:30:00 \
    on-event="/system script run telegram-ip-updater" \
    policy=read,write,test
```

---

## Проверка результата

```routeros
/ip firewall address-list print where list=TG
/log print where message~"Telegram"
```

> [!success] Ожидаемый результат
> В списке появятся сети Telegram (`91.108.4.0/22`, `149.154.160.0/20`, …), а в логе — строка `Added N IPv4 entries`.

---

## Использование списка в firewall

Пример: разрешить трафик к сетям Telegram.

```routeros
/ip firewall filter
add chain=forward dst-address-list=TG action=accept comment="allow Telegram"
```

---

## Возможные проблемы

> [!bug]- Fetch ругается на сертификат
> На старых сборках добавь `check-certificate=no` в команду `fetch` внутри скрипта.

> [!bug]- `as-value` не поддерживается
> RouterOS до 6.43 не умеет `fetch output=user as-value`. Нужна версия 6.43+ либо файловый вариант скрипта.

> [!bug]- Список `TG` пустой
> Проверь интернет-доступ роутера и `policy` скрипта/расписания (`read,write`). Скрипт намеренно НЕ очищает старый список, если новый ответ пустой.

---

## Связанные заметки

- [[cloudflare-ip-updater-obsidian|CloudFlare IP Updater]] — тот же подход для CloudFlare
- [[initial-setup]] — базовый firewall и interface-lists
