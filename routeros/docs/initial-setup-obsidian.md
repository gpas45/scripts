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
aliases:
  - initial-setup
  - initial-setup.rsc
---

# Initial Setup — расширенная настройка MikroTik

Скрипт [[initial-setup]] (`routeros/initial-setup.rsc`) — расширенный шаблон настройки роутера поверх [[autorun-obsidian|autorun]]: bridge, interface-lists, полноценный firewall с port knocking и anti-bruteforce, NAT, DNS, харднинг сервисов, OSPF-фильтры и автообновление прошивки.

> [!info] Назначение
> Привести роутер к безопасной базовой конфигурации «всё в одном файле». Настройки конкретного провайдера (адреса, маршруты, dhcp-client, пароли) сюда **намеренно не входят** — задавайте их отдельно для каждого аплинка.

> [!warning] Перед импортом
> - Назначьте реальные интерфейсы в `/interface list member` (LAN/WAN/StS/VPN).
> - Привяжите порты к bridge в `/interface bridge port`.
> - Проверьте часовой пояс и DNS-серверы.
> - Учтите последовательность port knocking: **1234 → 2345 → 3456**, затем подключение на порт **12345**.

> [!danger] Не заблокируйте себя
> Доступ к управлению с WAN открывается только через port knocking. Перед импортом убедитесь, что у вас есть доступ из `LAN` (он разрешён правилом `accept LAN`).

> [!warning] Финальные правила — `passthrough`, а не `drop`
> Замыкающие правила цепочек `input`/`forward` имеют `action=passthrough` (с комментарием «drop all other»): они **считают и логируют** нежелательный трафик, но **не отбрасывают** его. Это режим наблюдения — удобно «обкатать» правила, ничего не заблокировав. Чтобы включить полноценный **default-drop**, поменяйте `passthrough` на `drop` в этих двух правилах:
> ```routeros
> /ip firewall filter set [find comment="drop all other"] action=drop
> ```

---

## Что делает скрипт

| Раздел | Действие |
|---|---|
| `/interface bridge` | Создаёт `bridge` (порты добавляются отдельно). |
| `/interface list` + `member` | Списки `WAN`/`LAN`/`StS`/`VPN`, в LAN — `bridge`, в WAN — `ether1`. |
| `/ip firewall filter` | Цепочки `input`/`forward`/`icmp`/`pk`/`detect-intrusion`: established/related, drop invalid, port knocking, anti-bruteforce, ICMP-фильтр, межсегментные разрешения, финальный **passthrough** (счёт/лог; см. предупреждение ниже). |
| `/ip firewall nat` | `masquerade` для LAN → Internet через `WAN`. |
| `/ip dns` | Резолвер для LAN/VPN/StS (`allow-remote-requests`, серверы 1.1.1.1/8.8.8.8). |
| `/ip service` | Отключает `telnet/ftp/www/api/api-ssl`. |
| Neighbor / MAC-server | Discovery только в `LAN`; MAC-server временно открыт (см. предупреждение ниже). |
| `/tool bandwidth-server` | Выключает bandwidth-test (частый вектор атаки). |
| `/ipv6 settings` | `disable-ipv6=yes`. |
| `/system clock` + `ntp` | Часовой пояс, NTP-клиент и NTP-сервер для нижестоящих клиентов. |
| `/system logging` | Глушит info-сообщения dhcp/wireless/wifi. |
| `/system package update` | Канал обновлений — `long-term`. |
| `/system scheduler` | Автообновление прошивки RouterBOARD на старте (см. [[routerboard-fwupgrade-obsidian]]). |
| `/routing filter rule` | OSPF-фильтры: принимать/отдавать только RFC1918 (см. [[ospf-filter-rules-obsidian]]). |

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
> Цепочка `detect-intrusion` ограничивает частоту новых подключений и заносит «шумные» источники в `black-list attackers` на сутки.

---

## Установка

> [!tip] Импорт файла
> 1. Залить `initial-setup.rsc` в **Files** или скачать на роутер:
>    ```routeros
>    /tool fetch url="https://raw.githubusercontent.com/gpas45/scripts/main/routeros/initial-setup.rsc"
>    ```
> 2. Отредактировать interface-lists и bridge-порты под своё оборудование.
> 3. Импортировать:
>    ```routeros
>    /import file-name=initial-setup.rsc
>    ```

---

## Проверка результата

```routeros
/interface list member print
/ip firewall filter print
/ip firewall nat print
/ip dns print
/system scheduler print where name=routerboard_fwupgrade
/routing filter rule print
```

> [!success] Ожидаемый результат
> Заполненные interface-lists, цепочки firewall с финальным `passthrough`, активный NAT и DNS-резолвер, заданный scheduler обновления прошивки.

---

## Возможные проблемы

> [!bug]- Потерян доступ после импорта
> Доступ с WAN — только через port knocking. С LAN доступ разрешён правилом `accept LAN` — подключайтесь из локальной сети. При полной потере — сброс конфигурации/Netinstall.

> [!warning] MAC-server временно открыт на всех интерфейсах
> Чтобы роутер оставался доступен по MAC-telnet/MAC-winbox до получения IP, `mac-server`/`mac-winbox` оставлены `allowed-interface-list=all`. Это **открывает MAC-доступ и на WAN**. После настройки ограничьте список management-интерфейсом:
> ```routeros
> /tool mac-server set allowed-interface-list=LAN
> /tool mac-server mac-winbox set allowed-interface-list=LAN
> ```

> [!bug]- Не работает port knocking
> Проверьте, что «стук» идёт именно в правильном порядке и интервалы укладываются в таймауты `pk-1/pk-2/pk-3` (1 минута). Адрес добавляется в `management` только при наличии `pk-3`.

> [!bug]- OSPF-фильтры не применяются
> Правила `ospf-in`/`ospf-out` создаются, но не привязаны к инстансу. Привяжите их через `in-filter-chain`/`out-filter-chain` — подробности в [[ospf-filter-rules-obsidian]].

---

## Связанные заметки

- [[autorun-obsidian|autorun]] — минимальный bootstrap
- [[ospf-filter-rules-obsidian|OSPF filter rules]] — фильтры маршрутов
- [[routerboard-fwupgrade-obsidian|RouterBOARD Firmware Auto-Upgrade]]
- [[cloudflare-ip-updater-obsidian|CloudFlare IP Updater]] · [[telegram-ip-updater-obsidian|Telegram]] · [[google-ip-updater-obsidian|Google]]
