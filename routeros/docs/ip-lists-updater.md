---
title: IP Lists Updater — установка на MikroTik
tags:
  - mikrotik
  - routeros
  - firewall
  - google
  - youtube
  - telegram
  - cloudflare
  - script
created: 2026-11-08
updated: 2026-11-08
aliases:
  - VPN_ytb address-list
  - TG address-list
  - CF address-list
  - ip-lists-updater
---

# IP Lists Updater — установка на MikroTik

Скрипт `routeros/ip-lists-updater.rsc` заменил три отдельных апдейтера (Google, Telegram, CloudFlare — удалены из репозитория, лежат в истории git). Один запуск скачивает три официальных списка IPv4-сетей и наполняет **три разных** `address-list`.

| Источник | URL | address-list | `comment` своих записей |
|---|---|---|---|
| Google (вкл. YouTube) | `https://www.gstatic.com/ipranges/goog.json` | **`VPN_ytb`** | `google-auto` |
| Telegram | `https://core.telegram.org/resources/cidr.txt` | **`TG`** | `Telegram IPv4` |
| CloudFlare | `https://www.cloudflare.com/ips-v4/` | **`CF`** | `cloudflare IPv4` |

Имена списков и комментарии совпадают с теми, что создавали отдельные скрипты, поэтому **существующие правила firewall менять не нужно** — достаточно заменить три именованных скрипта и три задачи планировщика на один скрипт и одну задачу.

> [!info] Назначение
> Списки сами по себе ничего не блокируют и не разрешают — они используются в правилах firewall/mangle (например, «заворачивать трафик к Google в VPN-маршрут» или «разрешить Telegram»). Обновляются по расписанию, чтобы соответствовать официальным диапазонам.

> [!warning] goog.json — это ВСЕ диапазоны Google
> Файл `goog.json` содержит все публичные подсети Google, а не только YouTube. Отдельного официального списка «только YouTube» Google не публикует, поэтому маршрутизируемый набор будет шире, чем подразумевает имя `VPN_ytb`.

> [!note] Поведение при сбое
> Каждый источник обрабатывается независимо: если один URL не ответил или ответ пустой, его список остаётся **прежним**, а два других обновляются. Чистятся только свои записи — по паре `list` + `comment`, чужие адреса в этих списках не трогаются.

> [!warning] Требования
> - **RouterOS 6.43+** или **7.x** (используется `/tool fetch ... as-value`).
> - Доступ роутера в интернет к `gstatic.com`, `core.telegram.org`, `cloudflare.com` — из РФ, как правило, **через туннель**, см. [Маркировка исходящих пакетов](#маркировка-исходящих-пакетов-и-отправка-их-в-туннель).
> - Рабочий DNS на роутере (`/ip dns`).
> - Права скрипта: `read,write,test`.
> - **device-mode**: на новых устройствах (RouterOS 7.17+) режим `home` запрещает `fetch` и `scheduler`. Проверка — `/system device-mode print`, поднять режим — `/system device-mode update mode=advanced` + физическое подтверждение (кнопка reset/mode или снятие питания). См. [[initial-setup]].

---

## Из чего состоит установка

| Файл | Что делает | Когда запускать |
|---|---|---|
| `ip-updater.rsc` | Резолвит хосты-источники и наполняет address-list **`ip-updater`** — по нему mangle заворачивает исходящий трафик роутера в туннель. См. [[ip-updater]]. | Первым, за несколько минут до апдейтера списков |
| `ip-lists-updater.rsc` | Скачивает три списка и наполняет `VPN_ytb` / `TG` / `CF`. | Вторым |

---

## Способ 1. Разовый запуск через `import`

> [!tip] Когда использовать
> Быстро проверить работу или наполнить списки один раз, без автообновления.

### 1. Загрузить файлы на роутер

Перетащить `.rsc` в **Files** (Winbox/WebFig), или скачать прямо на роутер:

```routeros
/tool fetch url="https://raw.githubusercontent.com/gpas45/scripts/main/routeros/ip-updater.rsc"
```

```routeros
/tool fetch url="https://raw.githubusercontent.com/gpas45/scripts/main/routeros/ip-lists-updater.rsc"
```

### 2. Выполнить импорт

```routeros
/import file-name=ip-updater.rsc
```

```routeros
/import file-name=ip-lists-updater.rsc
```

После этого `VPN_ytb`, `TG` и `CF` наполнятся сразу.

---

## Способ 2. System script + автозапуск (рекомендуется)

> [!tip] Когда использовать
> Постоянная установка с обновлением по расписанию.

### 1. Создать именованные скрипты

```routeros
/system script
add name=ip-updater policy=read,write,test \
    source=[/file get ip-updater.rsc contents]
add name=ip-lists-updater policy=read,write,test \
    source=[/file get ip-lists-updater.rsc contents]
```

> [!note]
> Альтернатива — вставить тело скрипта вручную в `source={ ... }`, если файлы не загружали в Files.

### 2. Запустить вручную (проверка)

```routeros
/system script run ip-updater
```

```routeros
/system script run ip-lists-updater
```

### 3. Поставить на автообновление (раз в сутки)

```routeros
/system scheduler
add name=ip-updater interval=1d start-time=03:25:00 \
    on-event="/system script run ip-updater" \
    policy=read,write,test
add name=ip-lists-update interval=1d start-time=03:30:00 \
    on-event="/system script run ip-lists-updater" \
    policy=read,write,test
```

> [!note] Почему раз в сутки
> У отдельных скриптов интервалы были разные (Telegram — `1d`, CloudFlare и Google — `7d`). Объединённый скрипт ходит ко всем трём источникам сразу, поэтому интервал берётся по самому «живому» — `1d`. Нагрузка — три HTTPS-запроса в сутки.

### 4. Убрать старые скрипты и задачи (если ставились отдельные)

```routeros
/system scheduler remove [find name~"^(telegram|cloudflare|google)-update$"]
/system script remove [find name~"^(telegram|cloudflare|google)-ip-updater$"]
```

Сами записи в `VPN_ytb` / `TG` / `CF` удалять не нужно — объединённый скрипт перезапишет свои.

---

## Маркировка исходящих пакетов и отправка их в туннель

> [!important] Без этого шага обновление из РФ не работает
> `fetch` выполняет **сам роутер**, то есть пакеты идут через цепочку `output`, а не `prerouting`. Обычный policy-routing для клиентов за NAT на них не действует: трафик уйдёт через провайдера напрямую и до `gstatic.com` / `core.telegram.org` / `cloudflare.com` может не дойти. Поэтому исходящие пакеты к адресам из списка `ip-updater` нужно пометить и отправить в туннель.

### Шаг 0. Таблица маршрутизации и маршрут в туннель

RouterOS 7:

```routeros
/routing table add name=vpn-kvn fib comment="KVN RouterOS"
```

```routeros
/ip route add dst-address=0.0.0.0/0 gateway=<интерфейс-туннеля> routing-table=vpn-kvn comment="KVN RouterOS"
```

На RouterOS 6 таблица не создаётся отдельно — достаточно маршрута с `routing-mark=vpn-kvn`.

### Шаг 1. Списки адресов

- **`ip-updater`** — наполняет [[ip-updater|ip-updater.rsc]] (резолв хостов-источников).
- **`DNS`** — заполняется вручную адресами резолверов, которые тоже должны ходить через туннель:

```routeros
/ip firewall address-list
add list=DNS address=1.1.1.1 comment=DNS
add list=DNS address=8.8.8.8 comment=DNS
```

> [!tip]
> Те же адреса должны стоять в `/ip dns set servers=...` — иначе `ip-updater` будет резолвить через провайдерский DNS, который может отдавать подменённые ответы.

### Шаг 2. Правила mangle

```routeros
/ip firewall mangle
add action=mark-connection chain=output comment="KVN RouterOS" connection-mark=no-mark connection-state=new dst-address-list=ip-updater dst-address-type=!local new-connection-mark=vpn-out
add action=mark-connection chain=output connection-mark=no-mark connection-state=new dst-address-list=DNS dst-address-type=!local new-connection-mark=vpn-out
add action=mark-routing chain=output connection-mark=vpn-out connection-state="" new-routing-mark=vpn-kvn passthrough=no
```

Что делает каждое правило:

1. **Первое** — новые соединения роутера к адресам из `ip-updater` получают `connection-mark=vpn-out`. `connection-mark=no-mark` не даёт переразметить уже помеченное соединение, `dst-address-type=!local` исключает собственные адреса роутера.
2. **Второе** — то же для списка `DNS`: запросы резолвера уходят в туннель, иначе резолв отдаст «местные» ответы и в `ip-updater` попадут не те адреса.
3. **Третье** — все пакеты помеченного соединения (`connection-state=""` — любое состояние, не только `new`) получают `routing-mark=vpn-kvn` и уходят в таблицу с маршрутом в туннель. `passthrough=no` останавливает дальнейший разбор.

> [!warning] Порядок правил
> Правила должны стоять **выше** других правил цепочки `output`, которые метят соединения или маршрутизацию, иначе условие `connection-mark=no-mark` уже не сработает.

> [!note] NAT на туннеле
> Если туннель требует подмены адреса источника (большинство VPN-провайдеров), добавьте:
> ```routeros
> /ip firewall nat add chain=srcnat out-interface=<интерфейс-туннеля> action=masquerade comment="KVN RouterOS"
> ```

### Шаг 3. Проверка

```routeros
/ip firewall mangle print stats where chain=output
```

```routeros
/tool fetch url="https://www.gstatic.com/ipranges/goog.json" output=user as-value
```

```routeros
/ping 8.8.8.8 routing-table=vpn-kvn
```

> [!success] Ожидаемый результат
> На правилах mangle растут счётчики пакетов, `fetch` завершается со `status=finished`, `ping` через `vpn-kvn` проходит.

---

## Проверка результата

```routeros
/ip firewall address-list print where list=VPN_ytb
/ip firewall address-list print where list=TG
/ip firewall address-list print where list=CF
/log print where message~"IP lists updater"
```

> [!success] Ожидаемый результат
> В списках появятся сети Google (`8.8.4.0/24`, `34.0.0.0/9`, …), Telegram (`91.108.4.0/22`, `149.154.160.0/20`, …) и CloudFlare (`173.245.48.0/20`, `103.21.244.0/22`, …), а в логе — строки `downloaded successfully` и `added N IPv4 entries` по каждому источнику плюс итог `finished, added N entries`.

Счётчики в один запрос:

```routeros
:put ("VPN_ytb: " . [:len [/ip firewall address-list find list=VPN_ytb]] . " TG: " . [:len [/ip firewall address-list find list=TG]] . " CF: " . [:len [/ip firewall address-list find list=CF]])
```

---

## Использование списков в firewall / policy-routing

Заворачивать трафик клиентов к Google в таблицу с туннелем:

```routeros
/ip firewall mangle
add chain=prerouting dst-address-list=VPN_ytb action=mark-routing \
    new-routing-mark=vpn-kvn passthrough=no comment="route Google via VPN"
```

Разрешить трафик к Telegram:

```routeros
/ip firewall filter
add chain=forward dst-address-list=TG action=accept comment="allow Telegram"
```

Пропускать к веб-серверу только CloudFlare:

```routeros
/ip firewall filter
add chain=forward src-address-list=CF action=accept comment="allow Cloudflare"
```

---

## Возможные проблемы

> [!bug]- IP lists updater: <источник> - fetch failed
> Скрипт уже использует `check-certificate=no`, поэтому TLS обычно не виноват. Проверь причину вручную:
> ```routeros
> /tool fetch url="https://core.telegram.org/resources/cidr.txt" output=user as-value
> ```
> - `could not resolve` → нет DNS: `/ip dns set servers=1.1.1.1,8.8.8.8`
> - `host unreachable` / `timeout` → нет маршрута/интернета либо не настроена [маркировка исходящих пакетов](#маркировка-исходящих-пакетов-и-отправка-их-в-туннель)
> - `tls` / `certificate` → импортируй CA или оставь `check-certificate=no`
> - `not allowed by device-mode` → см. требования выше

> [!bug]- Обновился только один список из трёх
> Так и задумано при сбое источника: смотри `/log print where message~"IP lists updater"` — там будет видно, какой источник упал и почему. Остальные списки при этом актуальны.

> [!bug]- `as-value` не поддерживается
> RouterOS до 6.43 не умеет `fetch output=user as-value`. Нужна версия 6.43+ либо файловый вариант скрипта.

> [!bug]- Список пустой
> Проверь интернет-доступ роутера и `policy` скрипта/расписания (`read,write`). Скрипт намеренно **не** очищает старый список, если ответ пустой или в нём нет валидных префиксов.

> [!bug]- `fetch` работает из терминала, но не по расписанию
> У задачи планировщика должны быть права `read,write,test` — как у скрипта.

---

## Связанные заметки

- [[ip-updater]] — резолв хостов-источников в address-list `ip-updater`
- [[autorun]] — первоначальная настройка RouterOS
- [[initial-setup]] — базовый firewall и interface-lists
