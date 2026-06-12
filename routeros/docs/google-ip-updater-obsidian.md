---
title: Google IP Updater — установка на MikroTik
tags:
  - mikrotik
  - routeros
  - firewall
  - google
  - youtube
  - script
created: 2026-06-12
aliases:
  - google-ip-updater
  - VPN_ytb address-list
---

# Google IP Updater — установка на MikroTik

Скрипт [[google-ip-updater]] (`routeros/google-ip-updater.rsc`) скачивает официальный список IP-диапазонов Google (`goog.json`) и наполняет ими firewall `address-list` с именем **`VPN_ytb`**. Удобно для policy-routing/VPN на сервисы Google, включая YouTube.

> [!info] Назначение
> Список `VPN_ytb` сам по себе ничего не блокирует и не разрешает — он используется в правилах firewall/mangle (например, «заворачивать трафик к Google в VPN-маршрут»). Обновляется по расписанию, чтобы всегда соответствовать официальным диапазонам Google.

> [!warning] goog.json — это ВСЕ диапазоны Google
> Файл `goog.json` содержит все публичные подсети Google, а не только YouTube. Отдельного официального списка «только YouTube» Google не публикует, поэтому маршрутизируемый набор будет шире, чем подразумевает имя `VPN_ytb`.

> [!warning] Требования
> - **RouterOS 6.43+** или **7.x** (используется `/tool fetch ... as-value`).
> - Доступ роутера в интернет (HTTPS к `gstatic.com`).
> - Права скрипта: `read,write,test`.

---

## Способ 1. Разовый запуск через `import`

> [!tip] Когда использовать
> Быстро проверить работу или наполнить список один раз, без автообновления.

### 1. Загрузить файл на роутер

Перетащить `google-ip-updater.rsc` в **Files** (Winbox/WebFig), или скачать прямо на роутер:

```routeros
/tool fetch url="https://raw.githubusercontent.com/gpas45/scripts/main/routeros/google-ip-updater.rsc"
```

### 2. Выполнить импорт

```routeros
/import file-name=google-ip-updater.rsc
```

После этого `address-list VPN_ytb` наполнится сразу.

---

## Способ 2. System script + автозапуск (рекомендуется)

> [!tip] Когда использовать
> Постоянная установка с обновлением по расписанию.

### 1. Создать именованный скрипт

```routeros
/system script
add name=google-ip-updater policy=read,write,test \
    source=[/file get google-ip-updater.rsc contents]
```

> [!note]
> Альтернатива — вставить тело скрипта вручную в `source={ ... }`, если файл не загружали в Files.

### 2. Запустить вручную (проверка)

```routeros
/system script run google-ip-updater
```

### 3. Поставить на автообновление (раз в 7 дней)

```routeros
/system scheduler
add name=google-update interval=7d start-time=03:41:00 \
    on-event="/system script run google-ip-updater" \
    policy=read,write,test
```

---

## Проверка результата

```routeros
/ip firewall address-list print where list=VPN_ytb
/log print where message~"Google IP updater"
```

> [!success] Ожидаемый результат
> В списке появятся сети Google (`8.8.4.0/24`, `8.8.8.0/24`, `34.0.0.0/9`, …), а в логе — строка `Added N IPv4 prefixes`.

---

## Использование списка в firewall / policy-routing

Пример: заворачивать трафик к Google в отдельную таблицу маршрутизации (VPN).

```routeros
/ip firewall mangle
add chain=prerouting dst-address-list=VPN_ytb action=mark-routing \
    new-routing-mark=to-vpn passthrough=no comment="route Google via VPN"
```

Пример: просто разрешить трафик к Google.

```routeros
/ip firewall filter
add chain=forward dst-address-list=VPN_ytb action=accept comment="allow Google"
```

---

## Возможные проблемы

> [!bug]- Google IP updater: Fetch failed
> Скрипт уже использует `check-certificate=no`, поэтому TLS обычно не виноват. Проверь причину вручную:
> ```routeros
> /tool fetch url="https://www.gstatic.com/ipranges/goog.json" output=user as-value
> ```
> - `could not resolve` → нет DNS: `/ip dns set servers=1.1.1.1,8.8.8.8`
> - `host unreachable` / `timeout` → у роутера нет маршрута/интернета
> - `tls` / `certificate` → импортируй CA или оставь `check-certificate=no`

> [!bug]- `as-value` не поддерживается
> RouterOS до 6.43 не умеет `fetch output=user as-value`. Нужна версия 6.43+ либо файловый вариант скрипта.

> [!bug]- Список `VPN_ytb` пустой
> Проверь интернет-доступ роутера и `policy` скрипта/расписания (`read,write`). Скрипт намеренно НЕ очищает старый список, если новый ответ пустой или в нём нет валидных префиксов.

---

## Связанные заметки

- [[cloudflare-ip-updater]] — аналогичный апдейтер для CloudFlare
- [[telegram-ip-updater]] — аналогичный апдейтер для Telegram
- [[autorun]] — первоначальная настройка RouterOS
- [[initial-setup]] — базовый firewall и interface-lists
