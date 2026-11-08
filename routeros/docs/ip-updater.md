---
title: IP Updater — резолв хостов-источников в address-list
tags:
  - mikrotik
  - routeros
  - firewall
  - dns
  - script
created: 2026-11-08
updated: 2026-11-08
aliases:
  - ip-updater address-list
---

# IP Updater — резолв хостов-источников в address-list

Скрипт `routeros/ip-updater.rsc` резолвит хосты, с которых [[ip-lists-updater|ip-lists-updater.rsc]] скачивает списки адресов, и складывает полученные IP в firewall `address-list` с именем **`ip-updater`**.

| Хост | Зачем нужен |
|---|---|
| `www.gstatic.com` | `goog.json` — диапазоны Google → `VPN_ytb` |
| `core.telegram.org` | `cidr.txt` — сети Telegram → `TG` |
| `www.cloudflare.com` | `ips-v4` — сети CloudFlare → `CF` |
| `raw.githubusercontent.com` | загрузка самих `.rsc` через `/tool fetch` |

> [!info] Назначение
> Список `ip-updater` ничего не разрешает и не блокирует — он нужен mangle-правилам цепочки `output`, которые заворачивают исходящий трафик самого роутера в туннель. Без этого `/tool fetch` идёт напрямую через провайдера и до источников может не дойти. Правила mangle и маршрут в туннель — в [[ip-lists-updater#Маркировка исходящих пакетов и отправка их в туннель|инструкции к ip-lists-updater]].

> [!note] Записи только добавляются
> За один прогон `:resolve` отдаёт по одной A-записи на хост, а у CDN их несколько. Поэтому скрипт резолвит каждый хост несколько раз (`tries`, по умолчанию 3) и **дополняет** список, не удаляя прошлые адреса: неудачный резолв не оставит mangle-правило без адресов, а набор IP со временем становится полнее. Дубли не добавляются — перед записью проверяется боевой список.

> [!warning] Требования
> - RouterOS 6.43+ или 7.x.
> - Рабочий DNS на роутере: `/ip dns set servers=1.1.1.1,8.8.8.8`.
> - Права скрипта: `read,write,test`.
> - **device-mode**: в режиме `home` запрещён `scheduler`. См. [[initial-setup]].

---

## Настройки в начале скрипта

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `listName` | `ip-updater` | имя address-list; должно совпадать с `dst-address-list` в правилах mangle |
| `cmntPrefix` | `ip-updater:` | префикс комментария своих записей — по нему удобно чистить список |
| `dnsServer` | `""` | DNS-сервер для резолва; `""` — настройки роутера (`/ip dns`). Указать явно, если провайдерский DNS подменяет ответы |
| `tries` | `3` | сколько раз резолвить каждый хост за прогон |
| `hosts` | 4 хоста (таблица выше) | список хостов-источников |

Добавить свой хост — дописать в массив:

```routeros
:local hosts {"www.gstatic.com";"core.telegram.org";"www.cloudflare.com";"raw.githubusercontent.com";"example.com"}
```

---

## Способ 1. Разовый запуск через `import`

```routeros
/tool fetch url="https://raw.githubusercontent.com/gpas45/scripts/main/routeros/ip-updater.rsc"
```

```routeros
/import file-name=ip-updater.rsc
```

---

## Способ 2. System script + автозапуск (рекомендуется)

### 1. Создать именованный скрипт

```routeros
/system script
add name=ip-updater policy=read,write,test \
    source=[/file get ip-updater.rsc contents]
```

### 2. Запустить вручную (проверка)

```routeros
/system script run ip-updater
```

### 3. Поставить на автообновление

```routeros
/system scheduler
add name=ip-updater interval=1d start-time=03:25:00 \
    on-event="/system script run ip-updater" \
    policy=read,write,test
```

> [!important] Порядок запуска
> `ip-updater` должен отработать **раньше** `ip-lists-updater` — иначе mangle-правило не найдёт адресов и `fetch` уйдёт мимо туннеля. В примерах расписания — `03:25` против `03:30`.

---

## Проверка результата

```routeros
/ip firewall address-list print where list=ip-updater
/log print where message~"IP updater"
```

> [!success] Ожидаемый результат
> В списке появятся IP всех четырёх хостов, а в логе — строки `added <ip> (<host>)` и итог `added N new entries, 'ip-updater' now has M entries`.

---

## Обслуживание

Удалить свои записи и наполнить список заново:

```routeros
/ip firewall address-list remove [find list=ip-updater comment~"^ip-updater:"]
```

```routeros
/system script run ip-updater
```

Так как записи только накапливаются, периодическая чистка (раз в несколько месяцев) убирает IP, которые CDN уже не использует. Отдельной задачи планировщика для этого не нужно — список маленький.

---

## Возможные проблемы

> [!bug]- IP updater: resolve failed for <host>
> Не работает DNS на роутере. Проверь:
> ```routeros
> /ip dns print
> :put [:resolve "www.gstatic.com"]
> ```
> Если резолва нет — задай серверы: `/ip dns set servers=1.1.1.1,8.8.8.8`. Если ответ есть, но адреса явно «местные» (провайдерская подмена) — укажи `dnsServer` в начале скрипта и заверни список `DNS` в туннель, см. [[ip-lists-updater#Маркировка исходящих пакетов и отправка их в туннель|правила mangle]].

> [!bug]- Список растёт слишком быстро
> Это нормально для CDN: `gstatic.com` и `raw.githubusercontent.com` отдают много A-записей. Уменьши `tries` до 1 или периодически чисти список (см. «Обслуживание»).

> [!bug]- Записи есть, но fetch всё равно не проходит
> Проверь сами правила mangle и маршрут в туннель: счётчики на правилах `chain=output`, наличие таблицы `vpn-kvn` и маршрута `0.0.0.0/0` в ней. Разбор — в [[ip-lists-updater]].

---

## Связанные заметки

- [[ip-lists-updater]] — объединённый апдейтер списков Google / Telegram / CloudFlare
- [[initial-setup]] — базовый firewall и interface-lists
