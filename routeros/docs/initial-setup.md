---
title: Initial Setup — расширенная настройка MikroTik
tags:
  - mikrotik
  - routeros
  - firewall
  - hardening
  - port-knocking
  - script
created: 2026-06-13
updated: 2026-10-26
aliases:
  - initial-setup-ros6
  - initial-setup-ros7
  - initial-setup.rsc
---

# Initial Setup — расширенная настройка MikroTik

Расширенный шаблон настройки роутера поверх [[autorun|autorun]]: bridge, interface-lists, полноценный firewall с port knocking и anti-bruteforce, NAT, DNS, харднинг сервисов, OSPF-фильтры и автообновление прошивки.

Скрипт существует в двух версиях — синтаксис RouterOS 6 и 7 расходится:

| Файл | Для чего | Требования |
|---|---|---|
| `routeros/initial-setup-ros7.rsc` | RouterOS **7.x** | — |
| `routeros/initial-setup-ros6.rsc` | RouterOS **6.41+** | 6.41 — минимум для interface-lists / `in-interface-list` |

Версию посмотреть в `/system resource print` (строка `version`).

> [!info] Назначение
> Привести роутер к безопасной базовой конфигурации «всё в одном файле». Настройки конкретного провайдера (адреса, маршруты, dhcp-client, пароли) сюда **намеренно не входят** — задавайте их отдельно для каждого аплинка.

> [!warning] Перед импортом
> - Назначьте реальные интерфейсы в `/interface list member` (LAN/WAN/StS/VPN). В файле активна только строка `add list=LAN interface=bridge`; строка для WAN **закомментирована** — раскомментируйте и поправьте под свой аплинк, иначе правила с `in-interface-list=WAN` (port knocking, masquerade) работать не будут.
> - Привяжите порты к bridge в `/interface bridge port` — в скрипте они не заданы.
> - Проверьте часовой пояс (`Asia/Yekaterinburg`) и DNS-серверы (`1.1.1.1`, `8.8.8.8`).
> - Учтите последовательность port knocking: **1234 → 2345 → 3456**, затем подключение на порт **12345**.

> [!danger] Шаг 0 — на новых устройствах сначала `device-mode`
> На устройствах последних выпусков (RouterOS 7.17+) с завода включён ограничивающий **device-mode**, который запрещает часть функций независимо от прав пользователя. Домашние модели приходят в режиме `home`, где запрещены в том числе **`scheduler`** и **`fetch`** — то есть не сработает ни установка через `/tool fetch`, ни задача автообновления прошивки RouterBOARD, которую создаёт этот скрипт. Симптом: `not allowed by device-mode`.
>
> ```routeros
> /system device-mode print                       ;# текущий режим
> /system device-mode update mode=advanced        ;# поднять до advanced
> ```
> Или разрешить только нужное, не поднимая весь режим:
> ```routeros
> /system device-mode update scheduler=yes fetch=yes
> ```
> **Команда только запрашивает изменение.** В течение ~5 минут подтвердите его физически: нажмите на устройстве кнопку **reset** (или **mode**), либо снимите и подайте питание (**cold reboot**). Обычный `/system reboot` подтверждением не является — он отменяет запрос. На части снятых с производства моделей кнопка не работает, подтверждение только снятием питания.
>
> Делать это нужно **до** импорта: `/system reset-configuration` на многих моделях device-mode не сбрасывает. Подробности — в [`routeros/INSTALL.md`](../INSTALL.md).

> [!note] Заводские режимы по моделям
> | Режим | Где с завода | Что запрещено |
> |---|---|---|
> | `advanced` (ранее `enterprise`) | CCR, серия 1100, устройства, выпущенные до появления device-mode | по умолчанию закрыты `traffic-gen`, `container`, `partitions` |
> | `home` | домашние роутеры (hAP и подобные) | `scheduler`, `fetch`, `socks`, `bandwidth-test`, `traffic-gen`, `sniffer`, `romon`, `proxy`, `hotspot`, `email`, `zerotier`, `container` |
> | `basic` | остальные модели | набор зависит от модели и версии — смотрите вывод `print` |
>
> Апгрейд RouterOS режим не меняет, поэтому на давно работающих роутерах чаще всего уже `advanced` и делать ничего не нужно.

> [!danger] Ставить лучше на чистую конфигурацию
> Скрипт сам создаёт `bridge` и списки `WAN/LAN/StS/VPN`. Поверх заводского defconf эти объекты уже есть — будут дубли и ошибки импорта. Полный порядок установки, включая `/system reset-configuration no-defaults=yes`, описан в [`routeros/INSTALL.md`](../INSTALL.md).

> [!warning] Финальные правила — `passthrough`, а не `drop`
> Замыкающие правила цепочек `input`/`forward` имеют `action=passthrough` (комментарий `drop all other (see usage note 4: passthrough)`): они **считают и логируют** нежелательный трафик, но **не отбрасывают** его. Это режим наблюдения — удобно «обкатать» правила, ничего не заблокировав. Когда по логам видно, что нужный трафик проходит, включите полноценный default-drop:
> ```routeros
> /ip firewall filter set [find comment~"drop all other"] action=drop
> ```
> Сравнение по `~` обязательно: комментарий в правиле длиннее, чем просто `drop all other`.

---

## Что делает скрипт

| Раздел | Действие |
|---|---|
| `/interface bridge` | Создаёт `bridge` (порты добавляются отдельно). |
| `/interface list` + `member` | Списки `WAN`/`LAN`/`StS`/`VPN`; активно только членство `bridge` → `LAN`, остальные примеры закомментированы. |
| `/ip firewall filter` | Цепочки `input`/`forward`/`icmp`/`pk`/`detect-intrusion`: established/related, drop invalid, port knocking, anti-bruteforce, ICMP-фильтр, межсегментные разрешения, финальный **passthrough** (счёт/лог; см. предупреждение выше). |
| | Правила для туннелей (`GRE`, `IPsec IKE 500/4500`, `ESP`, `AH`, `L2TP 1701`) созданы, но **выключены** (`disabled=yes`) — включайте те, что нужны. GRE стоит **до** правила `drop invalid`: у GRE нет conntrack, иначе его пакеты отбрасываются как invalid. |
| `/ip firewall nat` | `masquerade` для LAN → Internet через `WAN`. Рядом — закомментированная альтернатива `src-nat` для статического внешнего адреса (не пересчитывает адрес на каждый пакет). |
| `/ip dns` | Резолвер для LAN/VPN/StS (`allow-remote-requests=yes`, серверы `1.1.1.1`, `8.8.8.8`). |
| `/ip service` | Отключает `telnet`, `ftp`, `www`, `api`. **`api-ssl` остаётся включённым** (`disabled=no`) — доступ к нему разрешён только из списка `management` (порт 8729). |
| Neighbor / MAC-server | Discovery и MAC-telnet/MAC-winbox ограничены списком `LAN`; `mac-server ping` выключен. |
| `/tool bandwidth-server` | Выключает bandwidth-test (частый вектор атаки). |
| IPv6 | **ROS7:** `/ipv6 settings set disable-ipv6=yes`. **ROS6:** `/system package disable hotspot,ipv6,mpls` — применяется только **после перезагрузки**. |
| `/system clock` + `ntp` | Часовой пояс, NTP-клиент и NTP-сервер для нижестоящих клиентов. **ROS7:** `set enabled=yes servers=pool.ntp.org`. **ROS6:** `set enabled=yes server-dns-names=pool.ntp.org`, причём NTP-**сервер** в ROS6 — отдельный пакет `ntp`, блок сработает только если он установлен. |
| `/system logging` | Глушит info-сообщения `dhcp`. Подавление беспроводных сообщений закомментировано: топик называется `wifi` (ROS7 + wifiwave2) или `wireless` (legacy-пакет) — раскомментируйте нужный. |
| `/system package update` | Канал обновлений — `long-term`. |
| `/system scheduler` | Автообновление прошивки RouterBOARD на старте (см. [[routerboard-fwupgrade]]). |
| OSPF-фильтры | Принимать/отдавать только RFC1918. **ROS7:** `/routing filter rule` с `rule="if (...) {accept;}"`. **ROS6:** `/routing filter` с `prefix` / `prefix-length` / `action`. Подробнее — [[ospf-filter-rules]]. |

> [!note] Чем ещё отличаются версии
> Кроме IPv6, NTP и OSPF — в ROS6-варианте у правила port knocking нет `log=yes` (в ROS6 оно слишком шумит), а глушить можно только топик `wireless`.

---

## Port knocking — как пользоваться

Последовательность «стука» открывает доступ к управлению с WAN:

1. TCP-подключение на порт **1234** → попадание в `pk-1` (на 1 минуту).
2. Затем на **2345** → `pk-2`.
3. Затем на **3456** → `pk-3`.
4. В течение действия `pk-3` подключение на **12345** добавляет ваш IP в `management` на **1 сутки**.
5. Из `management` разрешён доступ к `22, 8291, 8729` (SSH, Winbox, API-SSL).

```bash
# пример «стука» с клиента (nc/ncat)
for p in 1234 2345 3456; do nc -z -w1 ROUTER_IP $p; done
nc -z -w1 ROUTER_IP 12345
# теперь доступен SSH/Winbox в течение суток
```

> [!note] Anti-bruteforce
> Цепочка `detect-intrusion` ограничивает частоту новых подключений (`dst-limit=30,256,src-and-dst-addresses/1s`) и заносит «шумные» источники в `black-list attackers` на сутки. Источники из списка `management` в эту цепочку не попадают.

---

## Установка

> [!tip] Способ 1 — `fetch` + `import` (две команды)
> ```routeros
> /tool fetch url="https://raw.githubusercontent.com/gpas45/scripts/main/routeros/initial-setup-ros7.rsc" dst-path=setup.rsc check-certificate=no
> /import file-name=setup.rsc
> ```
> Для RouterOS 6 подставьте `initial-setup-ros6.rsc`. `check-certificate=no` нужен потому, что на свежем роутере часы не выставлены и проверка TLS-сертификата GitHub не пройдёт.

> [!tip] Способ 2 — вручную (приватный репозиторий / нет интернета)
> 1. Winbox/WebFig → **Files** → перетащить `.rsc` (или по SFTP/scp).
> 2. ```routeros
>    /import file-name=initial-setup-ros7.rsc
>    ```

Меньше одной команды не выйдет: `import` работает только с файлом на диске, «скачать и выполнить одной строкой» в RouterOS нет.

### Порядок на чистой железке

Сначала `device-mode` (см. шаг 0 выше), затем сброс:

```routeros
/system reset-configuration no-defaults=yes skip-backup=yes
```

Роутер перезагрузится с пустым конфигом и **без IP-адреса** — подключайтесь по MAC через Winbox, затем выполняйте `fetch` + `import`.

### После импорта

- **WAN**: адрес/шлюз или `dhcp-client` на аплинке.
- Раскомментировать `add list=WAN interface=ether1` под свой интерфейс.
- `/user set admin password=...`
- Порты в `bridge`, туннели StS/VPN, включение нужных `disabled=yes` правил IPsec/L2TP/GRE.
- **ROS6**: перезагрузка — отключение пакетов `hotspot/ipv6/mpls` применяется только после неё.
- Перевести замыкающие правила из `passthrough` в `drop` (см. выше).

Полная версия инструкции — [`routeros/INSTALL.md`](../INSTALL.md).

---

## Проверка результата

```routeros
/interface list member print
/ip firewall filter print
/ip firewall nat print
/ip dns print
/ip service print
/system scheduler print where name=routerboard_fwupgrade
/routing filter rule print           ;# ROS7
/routing filter print                ;# ROS6
```

> [!success] Ожидаемый результат
> Заполненные interface-lists, цепочки firewall с финальным `passthrough`, активный NAT и DNS-резолвер, заданный scheduler обновления прошивки.

---

## Возможные проблемы

> [!bug]- Ошибки импорта «already have such entry»
> Скрипт запущен поверх заводского defconf: `bridge` и interface-lists уже существуют. Сбросьте конфигурацию с `no-defaults=yes` и импортируйте заново.

> [!bug]- Потерян доступ после импорта
> Доступ с WAN — только через port knocking. С LAN доступ разрешён правилом `accept LAN` — подключайтесь из локальной сети, в том числе по MAC-winbox (`mac-server` разрешён в `LAN`). При полной потере — сброс конфигурации/Netinstall.

> [!bug]- Не работает port knocking, masquerade, правила по WAN
> Скорее всего в `WAN` не добавлен ни один интерфейс — строка `add list=WAN interface=ether1` в файле закомментирована. Проверьте: `/interface list member print where list=WAN`.

> [!bug]- Стучусь правильно, а в `management` не попадаю
> Интервалы должны укладываться в таймауты `pk-1/pk-2/pk-3` (1 минута каждый), и «стук» обязан идти со стороны WAN — правило имеет `in-interface-list=WAN`.

> [!bug]- `passthrough` не включился в `drop`
> `find comment="drop all other"` ничего не находит: полный комментарий — `drop all other (see usage note 4: passthrough)`. Используйте `[find comment~"drop all other"]`.

> [!bug]- ROS6: IPv6 остался включён
> `/system package disable` применяется только после перезагрузки. Проверьте `/system package print` — у пакета должен стоять флаг `X`.

> [!bug]- OSPF-фильтры не применяются
> Правила `ospf-in`/`ospf-out` создаются, но не привязаны к инстансу. Привяжите их через `in-filter-chain`/`out-filter-chain` — подробности в [[ospf-filter-rules]].

---

## Связанные заметки

- [[autorun|autorun]] — минимальный bootstrap
- [[ospf-filter-rules|OSPF filter rules]] — фильтры маршрутов отдельным файлом
- [[rdp-bruteforce|RDP brute-force protection]] — защита RDP поверх этого firewall
- [[routerboard-fwupgrade|RouterBOARD Firmware Auto-Upgrade]]
- [[backup-and-update|Backup & Update]] — бэкапы и обновление RouterOS
- [[cloudflare-ip-updater|CloudFlare IP Updater]] · [[telegram-ip-updater|Telegram]] · [[google-ip-updater|Google]]
- [[check-list-router|Чек-лист настройки роутера]]
