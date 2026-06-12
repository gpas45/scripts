---
title: CloudFlare IP Updater — установка на MikroTik
tags:
  - mikrotik
  - routeros
  - firewall
  - cloudflare
  - script
created: 2026-06-12
aliases:
  - cloudflare-ip-updater
  - CF address-list
---

# CloudFlare IP Updater — установка на MikroTik

Скрипт [[cloudflare-ip-updater]] (`routeros/cloudflare-ip-updater.rsc`) скачивает актуальный список IPv4-сетей CloudFlare и наполняет ими firewall `address-list` с именем **`CF`**.

> [!info] Назначение
> Список `CF` сам по себе ничего не блокирует и не разрешает — он используется в правилах firewall (например, «пропускать только CloudFlare к веб-серверу»). Обновляется по расписанию, чтобы всегда соответствовать официальным диапазонам CloudFlare.

> [!warning] Требования
> - **RouterOS 6.43+** или **7.x** (используется `/tool fetch ... as-value`).
> - Доступ роутера в интернет (HTTPS к `cloudflare.com`).
> - Права скрипта: `read,write,test`.

---

## Способ 1. Разовый запуск через `import`

> [!tip] Когда использовать
> Быстро проверить работу или наполнить список один раз, без автообновления.

### 1. Загрузить файл на роутер

Перетащить `cloudflare-ip-updater.rsc` в **Files** (Winbox/WebFig), или скачать прямо на роутер:

```routeros
/tool fetch url="https://raw.githubusercontent.com/gpas45/scripts/main/routeros/cloudflare-ip-updater.rsc"
```

### 2. Выполнить импорт

```routeros
/import file-name=cloudflare-ip-updater.rsc
```

После этого `address-list CF` наполнится сразу.

---

## Способ 2. System script + автозапуск (рекомендуется)

> [!tip] Когда использовать
> Постоянная установка с обновлением по расписанию.

### 1. Создать именованный скрипт

```routeros
/system script
add name=cloudflare-ip-updater policy=read,write,test \
    source=[/file get cloudflare-ip-updater.rsc contents]
```

> [!note]
> Альтернатива — вставить тело скрипта вручную в `source={ ... }`, если файл не загружали в Files.

### 2. Запустить вручную (проверка)

```routeros
/system script run cloudflare-ip-updater
```

### 3. Поставить на автообновление (раз в 7 дней)

```routeros
/system scheduler
add name=cloudflare-update interval=7d start-time=03:31:00 \
    on-event="/system script run cloudflare-ip-updater" \
    policy=read,write,test
```

---

## Проверка результата

```routeros
/ip firewall address-list print where list=CF
/log print where message~"cloudflare"
```

> [!success] Ожидаемый результат
> В списке появятся сети CloudFlare (`173.245.48.0/20`, `103.21.244.0/22`, …), а в логе — строка `Added N IPv4 entries`.

---

## Использование списка в firewall

Пример: разрешить трафик только из сетей CloudFlare к веб-серверу.

```routeros
/ip firewall filter
add chain=forward src-address-list=CF action=accept comment="allow Cloudflare"
```

---

## Возможные проблемы

> [!bug]- CloudFlare IP updater: Fetch failed
> Скрипт уже использует `check-certificate=no`, поэтому TLS обычно не виноват. Проверь причину вручную:
> ```routeros
> /tool fetch url="https://www.cloudflare.com/ips-v4/" output=user as-value
> ```
> - `could not resolve` → нет DNS: `/ip dns set servers=1.1.1.1,8.8.8.8`
> - `host unreachable` / `timeout` → у роутера нет маршрута/интернета
> - `tls` / `certificate` → импортируй CA или оставь `check-certificate=no`

> [!bug]- `as-value` не поддерживается
> RouterOS до 6.43 не умеет `fetch output=user as-value`. Нужна версия 6.43+ либо файловый вариант скрипта.

> [!bug]- Список `CF` пустой
> Проверь интернет-доступ роутера и `policy` скрипта/расписания (`read,write`). Скрипт намеренно НЕ очищает старый список, если новый ответ пустой.

---

## Связанные заметки

- [[autorun]] — первоначальная настройка RouterOS
- [[initial-setup]] — базовый firewall и interface-lists
