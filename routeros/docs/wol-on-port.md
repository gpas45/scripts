---
title: Wake-on-LAN по обращению на порт — установка на MikroTik
tags:
  - mikrotik
  - routeros
  - wol
  - firewall
  - scheduler
  - script
created: 2026-11-06
updated: 2026-11-06
aliases:
  - wol-on-port.rsc
  - Wake-on-LAN MikroTik
  - WoL по стуку на порт
---

# Wake-on-LAN по обращению на порт — установка на MikroTik

Скрипт `routeros/wol-on-port.rsc` будит выключенный компьютер, когда кто-то постучался на заданный TCP-порт: правило firewall кладёт источник в `address-list`, а задача планировщика видит непустой список и отправляет магический пакет через `/tool wol`.

> [!info] Как это работает
> Прямого «хука на срабатывание правила» в RouterOS нет, поэтому событие в firewall связывается со скриптом через address-list:
>
> 1. Правило firewall с `action=add-src-to-address-list` ловит пакет на нужный порт и кладёт источник в список **`wol-trigger`**.
> 2. Scheduler раз в 5 секунд запускает скрипт `wol-on-port`.
> 3. Скрипт видит непустой `wol-trigger`, очищает его и, если компьютер не отвечает на ping, отправляет WoL.
> 4. На 2 минуты ставится блокировка через список **`wol-cooldown`**, чтобы не слать пакеты каждые 5 секунд, пока машина грузится.
>
> Первое TCP-подключение всегда отвалится — компьютер в этот момент ещё спит. Повторить через 30–60 секунд.

> [!warning] Требования
> - RouterOS 6.x / 7.x; компьютер и роутер — в одном L2-сегменте (WoL не маршрутизируется).
> - Права скрипта и планировщика: `read,write,test` (`test` нужен для `/ping` и `/tool wol`).
> - На компьютере включён Wake-on-LAN — см. раздел «Настройка компьютера».
> - **device-mode**: на новых устройствах (RouterOS 7.17+) режим `home` запрещает `fetch` и `scheduler`. Проверка — `/system device-mode print`, поднять режим — `/system device-mode update mode=advanced` + физическое подтверждение (кнопка reset/mode или снятие питания).

---

## 1. Узнать интерфейс компьютера

Самая частая ошибка — указать в `/tool wol` бридж вместо VLAN-интерфейса. Если на бридже `vlan-filtering=yes`, пакет, отправленный на сам бридж, уйдёт нетегированным в PVID бриджа и до нужной VLAN не доедет.

```routeros
/ip dhcp-server lease print where mac-address="AA:BB:CC:DD:EE:FF"
```

Или, если компьютер сейчас включён:

```routeros
/ip arp print where address=192.168.88.10
```

Колонка `interface` в выводе — это и есть значение для настройки `iface` (например `vlan3`, `vlan5`).

> [!note]
> После выключения машины запись из ARP пропадает, поэтому у спящего компьютера интерфейс смотрят по DHCP-лизу или по тому, в какой подсети его статический адрес.

---

## 2. Загрузить файл и заполнить настройки

Перетащить `wol-on-port.rsc` в **Files** (Winbox/WebFig), или скачать прямо на роутер:

```routeros
/tool fetch url="https://raw.githubusercontent.com/gpas45/scripts/main/routeros/wol-on-port.rsc"
```

Отредактировать секцию `НАСТРОЙКИ` (WebFig → Files → Edit), заменив все `CHANGE_ME`:

```routeros
:local mac   "AA:BB:CC:DD:EE:FF"
:local iface "vlan3"
:local pcip  "192.168.88.10"
:local checkPing true
:local cooldown 2m
```

| Параметр | Что это |
| --- | --- |
| `mac` | MAC компьютера, которому шлём магический пакет. |
| `iface` | VLAN-интерфейс (или бридж без vlan-filtering), в котором живёт компьютер. |
| `pcip` | IP компьютера: проверка «уже включён» и ключ для cooldown. |
| `checkPing` | `false`, если у роутера нет адреса в этой подсети или ICMP на машине закрыт. |
| `cooldown` | Пауза после успешной отправки — примерное время загрузки машины. |

---

## 3. Создать скрипт и планировщик

```routeros
/system script
add name=wol-on-port policy=read,write,test \
    source=[/file get wol-on-port.rsc contents]

/system scheduler
add name=wol-on-port interval=5s policy=read,write,test \
    on-event="/system script run wol-on-port"
```

> [!note]
> Скрипт читается из файла один раз, при создании. После правки `.rsc` команду `add` нужно повторить, предварительно удалив старый скрипт, — иначе на роутере останется прежняя версия.

---

## 4. Добавить правило-триггер в firewall

Выбрать один вариант.

> [!tip]- Вариант А — порт проброшен на сам компьютер
> Стучимся из интернета на проброшенный RDP. В цепочке `forward` адрес назначения уже после dst-nat, поэтому указываем внутренний IP:
>
> ```routeros
> /ip firewall filter
> add chain=forward protocol=tcp dst-port=3389 dst-address=192.168.88.10 \
>     action=add-src-to-address-list address-list=wol-trigger \
>     address-list-timeout=30s comment="wol-on-port trigger" place-before=0
> ```

> [!tip]- Вариант Б — «секретный» порт самого роутера
> Port knocking: роутеру не нужно ничего слушать на этом порту, правило срабатывает на самом факте прихода пакета.
>
> ```routeros
> /ip firewall filter
> add chain=input protocol=tcp dst-port=9999 \
>     action=add-src-to-address-list address-list=wol-trigger \
>     address-list-timeout=30s comment="wol-on-port trigger" place-before=0
> ```

> [!important] Про размещение правила
> `add-src-to-address-list` — **нетерминирующее** действие: пакет идёт дальше по цепочке, существующие правила не ломаются. Но `place-before=0` обязателен: правило должно стоять выше любых `drop`, иначе до него ничего не дойдёт.

---

## Проверка

Отправить магический пакет вручную — компьютер должен проснуться:

```routeros
/tool wol mac=AA:BB:CC:DD:EE:FF interface=vlan3
```

Проверить триггер: постучаться на порт и сразу посмотреть список (он живёт 30 секунд):

```routeros
/ip firewall address-list print where list=wol-trigger
```

Логи работы скрипта:

```routeros
/log print where message~"wol-on-port"
```

> [!success] Ожидаемый результат
> В логе — `wol-on-port: magic packet sent to AA:BB:CC:DD:EE:FF via vlan3`, а в `/ip firewall address-list print where list=wol-cooldown` на 2 минуты появляется запись.

---

## Настройка компьютера

> [!warning] Без этого роутер шлёт пакеты в пустоту
> - **BIOS/UEFI**: `Wake on LAN` / `PCIe Power On` / `Power On By PCI-E` — включить.
> - **Windows**, свойства сетевой карты → Управление электропитанием: «Разрешить этому устройству выводить компьютер из ждущего режима» и «Разрешить только магический пакет».
> - **Windows**, быстрый запуск (fast startup) — отключить. Иначе при «Завершении работы» карта обесточивается и из полного выключения машина не просыпается, хотя из сна просыпается нормально.
> - Проверить текущее состояние: `powercfg /devicequery wake_armed`.

---

## Возможные проблемы

> [!bug]- Скрипт пишет «magic packet sent», но компьютер не просыпается
> Чаще всего дело в интерфейсе. Проверь, что в `iface` указан **VLAN-интерфейс**, а не бридж с `vlan-filtering=yes`; сравни с выводом `/ip dhcp-server lease print`. Второй по частоте повод — fast startup в Windows.

> [!bug]- WoL отправляется постоянно, каждые несколько секунд
> Правило-триггер ловит слишком много: например, в цепочке `forward` без `dst-address` в список попадает любой трафик на этот порт. Сузь условие (`dst-address`, `in-interface`, `connection-state=new`) и проверь, что список `wol-cooldown` вообще создаётся — за это отвечает право `write` у скрипта.

> [!bug]- Скрипт не срабатывает, список `wol-trigger` всегда пуст
> Правило стоит ниже `drop` в цепочке. Проверь порядок (`/ip firewall filter print chain=forward`) и счётчики пакетов на самом правиле: если они не растут, до правила трафик не доходит.

> [!bug]- `/ping` всегда возвращает 0, WoL шлётся даже на включённую машину
> У роутера нет IP-адреса в подсети компьютера, либо ICMP закрыт брандмауэром Windows. Поставь `checkPing false` — защитой от повторов останется только cooldown.

> [!bug]- `not allowed by device-mode`
> Заводской `device-mode=home` на RouterOS 7.17+ запрещает scheduler и fetch. Поднять до `advanced` и подтвердить физически — кнопкой reset/mode или снятием питания (обычный `/system reboot` запрос отменяет).

> [!bug]- Компьютер в другой подсети, за маршрутизатором
> WoL — широковещательный L2-пакет, он не маршрутизируется. `/tool wol` должен выполняться на устройстве, которое физически в одном сегменте с машиной. Для удалённого сегмента нужен отдельный «будильник» на месте.

---

## Связанные заметки

- [[rdp-bruteforce]] — защита того же RDP-порта от перебора
- [[initial-setup]] — базовый firewall и interface-lists
