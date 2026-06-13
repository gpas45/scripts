---
title: Dual-WAN ISP Failover — проверка каналов на MikroTik
tags:
  - mikrotik
  - routeros
  - dual-wan
  - failover
  - script
created: 2026-06-13
aliases:
  - check-isp
  - check-isp.rsc
  - dual-wan failover
---

# Dual-WAN ISP Failover — проверка каналов на MikroTik

Скрипт [[check-isp]] (`routeros/check-isp.rsc`) проверяет доступность двух провайдеров пингом через каждый аплинк. Если канал «лёг» (ноль успешных ответов) — сбрасывает его помеченные соединения из conntrack, чтобы сессии переехали на живого провайдера.

> [!info] Назначение
> Ускорить переключение между двумя ISP при отказе одного из каналов. Сам по себе скрипт **не настраивает** маршрутизацию — он лишь чистит conntrack-записи упавшего канала; за раздачу трафика отвечают ваши mangle-правила и маршруты.

> [!warning] Требования и предпосылки
> - Два аплинка: `ether1` (ISP1) и `ether2` (ISP2) — поправьте `Isp1Iface`/`Isp2Iface`, если интерфейсы другие.
> - Mangle-правила, помечающие соединения как `con-isp1` / `con-isp2` (`connection-mark`).
> - Маршруты/таблицы для каждого ISP (policy-routing или `check-gateway`).
> - Права scheduler/скрипта: `read,write,test`.

---

## Настройки скрипта

```routeros
:local PingCount 5;            # эхо-запросов на проверку
:local Isp1Iface "ether1";     # аплинк ISP1
:local Isp2Iface "ether2";     # аплинк ISP2
:local CheckIp1 77.88.8.8;     # хост, пингуемый через ISP1
:local CheckIp2 77.88.8.1;     # хост, пингуемый через ISP2
```

> [!note] Логика «канал упал»
> Падением считается **только полное отсутствие** ответов (`0` из `PingCount`). Частичные потери (например, 2 из 5) failover не запускают — это защита от ложных срабатываний.

---

## Как это работает

1. `[/ping $CheckIpN ... interface=$IspNIface]` возвращает число успешных ответов через конкретный интерфейс.
2. Если для ISP1 ответов `0` → лог `ISP1 down`, удаление соединений с `connection-mark="con-isp1"`, лог `ISP1 connection reset`.
3. То же самое для ISP2.
4. После сброса conntrack новые пакеты пере-маркируются и уходят через живой канал.

> [!tip] Зачем чистить conntrack
> Уже установленные сессии «прилипают» к маршруту через `connection-mark`. Пока запись жива, трафик упорно идёт в мёртвый канал. Удаление помеченных соединений заставляет роутер промаркировать их заново — уже через рабочего ISP.

---

## Установка (scheduler)

```routeros
/system scheduler
add name=check-isp interval=30s policy=read,write,test \
    on-event="/import file-name=check-isp.rsc"
```

> [!note] Альтернатива — system script
> Можно завести именованный скрипт и запускать его из планировщика (`/system script run check-isp`) — так же, как у IP-апдейтеров. Импорт `.rsc` напрямую тоже работает.

---

## Проверка результата

```routeros
/log print where message~"ISP"
/ip firewall connection print count-only where connection-mark="con-isp1"
/ping 77.88.8.8 count=3 interface=ether1
/ping 77.88.8.1 count=3 interface=ether2
```

> [!success] Ожидаемый результат
> При обрыве одного из каналов в логе появляются `ISPx down` → `ISPx connection reset`, а трафик продолжает ходить через второй аплинк.

---

## Возможные проблемы

> [!bug]- Failover не срабатывает
> Проверьте, что пинг-хосты (`CheckIp1`/`CheckIp2`) реально доступны через свои интерфейсы, а mangle-правила действительно ставят `connection-mark=con-isp1/con-isp2`. Без меток `remove` ничего не находит.

> [!bug]- Трафик не возвращается на восстановленный канал
> Скрипт чистит соединения только упавшего канала. Возврат сессий назад зависит от ваших маршрутов/таймаутов conntrack; для «прилипчивых» соединений это нормальное поведение.

> [!bug]- Ложные переключения
> Слишком маленький `PingCount` или нестабильный пинг-хост дают ложные `down`. Увеличьте `PingCount` или выберите более надёжный адрес у каждого провайдера.

> [!warning] Частота запуска
> `interval=30s` + `PingCount=5` с двумя `:delay 2s` означает, что один прогон может занимать несколько секунд. Не ставьте интервал меньше суммарного времени проверки.

---

## Связанные заметки

- [[initial-setup-obsidian|initial-setup]] — базовый firewall и interface-lists
- [[autorun-obsidian|autorun]] — первичная настройка роутера
