---
title: RDP Brute-force Protection — защита RDP на MikroTik
tags:
  - mikrotik
  - routeros
  - firewall
  - rdp
  - bruteforce
  - script
created: 2026-10-26
updated: 2026-10-26
aliases:
  - rdp-bruteforce.rsc
  - RDP bruteforce
---

# RDP Brute-force Protection — защита RDP на MikroTik

Конфиг `routeros/rdp-bruteforce.rsc` создаёт mangle-правила, которые ловят повторяющиеся попытки подключения к RDP (TCP/3389) и ступенчато продвигают источник по пяти address-list'ам. Кто продолжает стучаться — попадает в `black-list attackers` на **4w2d** и отбрасывается правилом в `/ip firewall filter`.

> [!info] Назначение
> Отсечь автоматический перебор пароля RDP до того, как он дойдёт до опубликованного терминального сервера. Правила работают в цепочке `forward`, то есть защищают **хосты за роутером**, а не сам роутер.

> [!warning] Требования и предпосылки
> - RDP-сервер опубликован через `dst-nat` (трафик идёт через `forward`).
> - Списки `RDP` и `management` вы наполняете **сами** (см. ниже) — пустой список `RDP` означает, что легитимные клиенты тоже будут стадироваться.
> - Правило `drop` нужно **поднять в начало** цепочки `forward`, иначе бан не срабатывает мгновенно.
> - На новых устройствах (RouterOS 7.17+) для установки через `/tool fetch` нужен `device-mode` не ниже разрешённого `fetch` — см. [[initial-setup]]. Сами правила firewall device-mode не ограничивает.

---

## Как работает стадирование

Правила идут в порядке «старшая стадия → младшая» специально: за один новый коннект источник продвигается ровно на одну ступень и не проскакивает все списки сразу.

| Источник | Куда попадает | Таймаут |
|---|---|---|
| неизвестный (не в `management`) | `rdp_stage1` | 3m |
| уже в `rdp_stage1` | `rdp_stage2` | 3m |
| уже в `rdp_stage2` | `rdp_stage3` | 3m |
| уже в `rdp_stage3` | `rdp_stage4` | 3m |
| уже в `rdp_stage4` | `rdp_stage5` | 5m |
| уже в `rdp_stage5` | **`black-list attackers`** | **4w2d** → `drop` |

Итого до бана нужно 6 новых подключений, уложенных в таймауты стадий. Обычный пользователь, подключившийся один раз, доходит максимум до `rdp_stage1` и через 3 минуты выпадает из списка.

> [!note] Кто не банится никогда
> - Источники из списка **`RDP`** — правило `accept` стоит выше последнего `add-src-to-address-list` (белый список доверенных клиентов).
> - Источники из списка **`management`** — последнее правило имеет `src-address-list=!management`.
> - Адреса из **`192.168.0.0/16`** — правило бана имеет `src-address=!192.168.0.0/16` (защита от самоблокировки из локальной сети).

---

## Установка

> [!tip] Шаг 1 — импорт файла
> Залить `rdp-bruteforce.rsc` в **Files** (Winbox/WebFig перетаскиванием) или скачать прямо на роутер:
> ```routeros
> /tool fetch url="https://raw.githubusercontent.com/gpas45/scripts/main/routeros/rdp-bruteforce.rsc"
> /import file-name=rdp-bruteforce.rsc
> ```
> Импорт выполняется **один раз** — он создаёт постоянные правила, расписание не нужно.

> [!warning] Шаг 2 — поднять правило `drop` в начало цепочки
> `import` добавляет правило `drop` в конец `forward`, где выше него уже стоят `accept`-правила. Переместите его наверх:
> ```routeros
> /ip firewall filter print where comment~"RDP bruteforce"
> /ip firewall filter move [find comment~"RDP bruteforce"] destination=0
> ```
> Номер `destination` подберите под свою цепочку — правило должно стоять до любых `accept` для проброшенного RDP.

> [!tip] Шаг 3 — наполнить белые списки
> ```routeros
> /ip firewall address-list
> add list=RDP        address=203.0.113.10  comment="офис, статический IP"
> add list=management address=198.51.100.5  comment="админ"
> ```
> Если постоянных адресов у клиентов нет, белый список бесполезен — тогда вместо публикации RDP в интернет правильнее заводить пользователей через VPN.

---

## Проверка результата

```routeros
/ip firewall mangle print where dst-port=3389
/ip firewall filter print where comment~"RDP bruteforce"
/ip firewall address-list print where list~"rdp_stage"
/ip firewall address-list print where list="black-list attackers"
```

> [!success] Ожидаемый результат
> Семь mangle-правил на `dst-port=3389`, одно `drop`-правило в `forward`, а через несколько минут работы в интернете — непустые `rdp_stage1`/`rdp_stage2` и постепенно наполняющийся `black-list attackers`.

Посмотреть, кто забанен и сколько ему осталось:

```routeros
/ip firewall address-list print detail where list="black-list attackers"
```

Снять бан с конкретного адреса:

```routeros
/ip firewall address-list remove [find list="black-list attackers" address="203.0.113.77"]
```

---

## Возможные проблемы

> [!bug]- Списки `rdp_stage*` пустые
> Трафик не проходит через цепочку `forward`: либо RDP не проброшен через `dst-nat`, либо порт не 3389, либо соединения отбрасываются раньше другим правилом. Проверьте счётчики: `/ip firewall mangle print stats where dst-port=3389`.

> [!bug]- Адрес в `black-list attackers`, но подключения продолжаются
> Правило `drop` стоит ниже разрешающих правил. Переместите его в начало цепочки `forward` (см. шаг 2).

> [!bug]- Забанились легитимные пользователи
> Так работает любой RDP-брут-форс-фильтр при динамических адресах у клиентов. Добавьте их сети в список `RDP`, либо увеличьте таймауты стадий, либо (правильный вариант) уберите RDP из интернета и пустите клиентов через VPN.

> [!bug]- Забанился сам себя / админ
> Проверьте, что ваш адрес в `management` или `RDP`. Из `192.168.0.0/16` бан невозможен, но другие частные диапазоны (`10.0.0.0/8`, `172.16.0.0/12`) правилом **не** исключены — при необходимости добавьте их в `management`.

> [!warning] RDP в интернете — всегда риск
> Стадирование снижает шум и останавливает массовый перебор, но не защищает от уязвимостей самого RDP и от целевой атаки с ротацией адресов. Публикация RDP наружу остаётся компромиссом; VPN (IPsec/L2TP/WireGuard) надёжнее.

---

## Удаление

Сначала посмотрите, что удаляете — на `dst-port=3389` могут быть и ваши собственные правила:

```routeros
/ip firewall mangle print where dst-port=3389
```

Затем:

```routeros
/ip firewall mangle remove [find dst-port=3389 action~"add-src-to-address-list|accept"]
/ip firewall filter remove [find comment~"RDP bruteforce"]
/ip firewall address-list remove [find list~"rdp_stage"]
/ip firewall address-list remove [find list="black-list attackers"]
```

---

## Связанные заметки

- [[initial-setup|initial-setup]] — базовый firewall, port knocking и цепочка `detect-intrusion`
- [[check-list-router|Чек-лист настройки роутера]]
- [[autorun|autorun]] — первичная настройка роутера
