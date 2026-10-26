---
title: Autorun / Bootstrap — первичная настройка MikroTik
tags:
  - mikrotik
  - routeros
  - bootstrap
  - hardening
  - script
created: 2026-06-13
updated: 2026-10-26
aliases:
  - autorun.rsc
---

# Autorun / Bootstrap — первичная настройка MikroTik

Скрипт `routeros/autorun.rsc` — минимальный загрузочный шаблон: базовая адресация, NAT, отключение небезопасных сервисов и синхронизация времени. Подходит для быстрого ввода нового роутера в строй.

> [!info] Назначение
> Привести «коробочный» роутер к безопасному минимуму одной командой импорта. Для полноценного firewall и interface-lists смотри расширенный [[initial-setup|initial-setup]].

> [!warning] Перед импортом замените заглушки
> - `add address= interface=ether1 ...` — поле `address=` **пустое**, его обязательно нужно заполнить в формате `IP/префикс` (например, `203.0.113.2/24`), иначе импорт упадёт.
> - `gateway=10.0.0.1` — шлюз по умолчанию (`CHANGE_ME`).
> - `set 0 password="CHANGE_ME"` — пароль администратора (пользователь `0`).
> - `time-zone-name=Asia/Yekaterinburg` — свой часовой пояс при необходимости.

---

## Что делает скрипт

| Раздел | Действие |
|---|---|
| `/ip address`, `/ip route` | Статический адрес на `ether1` и шлюз по умолчанию. |
| `/ip dhcp-client` | Заготовка DHCP-клиента на `ether1` (по умолчанию `disabled=yes`). |
| `/interface list` + `member` | Списки `WAN`, `LAN`, `StS`, `VPN`; в `WAN` добавлен `ether1`. |
| `/ip firewall nat` | `masquerade` для трафика LAN → Internet через интерфейсы списка `WAN`. |
| `/user` | Пароль администратора. |
| `/ip service` | Отключает `telnet`, `ftp`, `www`, `api`, `api-ssl`. |
| Neighbor / MAC-server | Отключает обнаружение соседей и MAC-доступ (winbox/telnet/ping). |
| `/ipv6 settings` | `disable-ipv6=yes`. |
| `/system clock` + `ntp` | Часовой пояс (`Asia/Yekaterinburg`) и синхронизация времени с `pool.ntp.org`. |

> [!warning] На новых устройствах сначала `device-mode`
> На устройствах последних выпусков (RouterOS 7.17+) домашние модели приходят с завода в режиме `home`, где запрещены `fetch` и `scheduler` — установка через `/tool fetch` не сработает (`not allowed by device-mode`). Проверить и поднять режим:
> ```routeros
> /system device-mode print
> /system device-mode update mode=advanced
> ```
> Изменение нужно подтвердить физически в течение ~5 минут: кнопка **reset**/**mode** на устройстве либо снятие питания. Обычный `/system reboot` запрос отменяет. Подробности — в [[initial-setup]] и [`routeros/INSTALL.md`](../INSTALL.md).

> [!danger] MAC-доступ отключается полностью
> В отличие от [[initial-setup|initial-setup]], здесь `mac-server` выключен на всех интерфейсах. Убедитесь, что у вас есть рабочий IP-доступ (адрес/шлюз заданы верно), иначе после импорта можно потерять управление и понадобится сброс/Netinstall.

---

## Установка

> [!tip] Способ 1 — импорт файла
> 1. Залить `autorun.rsc` в **Files** (Winbox/WebFig перетаскиванием) или скачать на роутер:
>    ```routeros
>    /tool fetch url="https://raw.githubusercontent.com/gpas45/scripts/main/routeros/autorun.rsc" check-certificate=no
>    ```
>    `check-certificate=no` нужен потому, что на свежем роутере часы ещё не выставлены (NTP не отработал) и проверка TLS-сертификата GitHub не пройдёт.
> 2. Отредактировать заглушки `CHANGE_ME` в файле (например, через WebFig → Files → Edit).
> 3. Импортировать:
>    ```routeros
>    /import file-name=autorun.rsc
>    ```

> [!tip] Способ 2 — вручную
> Скопировать содержимое, заменить заглушки и вставить в терминал RouterOS.

---

## Нюанс с синтаксисом NTP

Скрипт задаёт NTP-серверы через подменю:

```routeros
/system ntp client servers
add address=pool.ntp.org
```

Эта форма есть не во всех версиях. Если импорт падает на этой строке, используйте вариант под свою ветку RouterOS:

```routeros
/system ntp client set enabled=yes servers=pool.ntp.org              ;# RouterOS 7 (документированный способ)
/system ntp client set enabled=yes server-dns-names=pool.ntp.org     ;# RouterOS 6
```

> [!note] Нужен рабочий DNS
> Имя `pool.ntp.org` резолвится при каждом запросе времени, поэтому без `/ip dns` NTP не заработает. На самом раннем этапе можно задать IP-адреса серверов напрямую.

---

## Проверка результата

```routeros
/ip address print
/ip route print where dst-address=0.0.0.0/0
/ip service print
/system ntp client print
/ping 8.8.8.8 count=3
```

> [!success] Ожидаемый результат
> Адрес на `ether1`, дефолтный маршрут, отключённые `telnet/ftp/www/api`, активный NTP-клиент и проходящий пинг во внешнюю сеть.

---

## Возможные проблемы

> [!bug]- Импорт падает на `/ip address`
> Поле `address=` должно быть в формате `IP/префикс` (например, `203.0.113.2/24`). Пустое значение приводит к ошибке импорта.

> [!bug]- Потерян доступ к роутеру после импорта
> Скрипт отключает MAC-server и небезопасные сервисы. Подключайтесь по IP (Winbox по адресу/порту 8291 или SSH). При полной потере доступа — сброс конфигурации или Netinstall.

> [!bug]- Нет интернета / не синхронизируется время
> Проверьте `address`/`gateway` и DNS (`/ip dns set servers=1.1.1.1,8.8.8.8`). Без DNS `pool.ntp.org` не резолвится.

---

## Связанные заметки

- [[initial-setup|initial-setup]] — расширенная настройка (firewall, port knocking, OSPF-фильтры)
- [[routerboard-fwupgrade|RouterBOARD Firmware Auto-Upgrade]]
- [[cloudflare-ip-updater|CloudFlare IP Updater]]
