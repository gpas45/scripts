---
title: RouterBOARD Firmware Auto-Upgrade — установка на MikroTik
tags:
  - mikrotik
  - routeros
  - firmware
  - scheduler
  - script
created: 2026-06-12
aliases:
  - routerboard_fwupgrade
  - RouterBOARD firmware upgrade
---

# RouterBOARD Firmware Auto-Upgrade — установка на MikroTik

Скрипт [[routerboard_fwupgrade]] (`routeros/routerboard_fwupgrade`) создаёт **scheduler**, который при каждой загрузке сверяет текущую прошивку RouterBOARD с доступной и, если появилась новее, обновляет её и перезагружает роутер.

> [!info] Зачем
> Прошивка RouterBOARD обновляется **отдельно** от пакетов RouterOS. После планового апгрейда RouterOS прошивка остаётся старой, пока её не применишь вручную. Этот scheduler делает это автоматически на старте.

> [!warning] Требования
> - RouterOS 6.x / 7.x на устройстве RouterBOARD.
> - Права scheduler: `reboot,read,write,sensitive`.
> - Учитывай, что обновление прошивки **перезагружает роутер**.

---

## Установка

> [!tip] Способ 1 — импорт файла
> 1. Залить файл `routerboard_fwupgrade` в **Files** (Winbox/WebFig перетаскиванием) или скачать на роутер:
>    ```routeros
>    /tool fetch url="https://raw.githubusercontent.com/gpas45/scripts/main/routeros/routerboard_fwupgrade"
>    ```
> 2. Импортировать (создаст scheduler):
>    ```routeros
>    /import file-name=routerboard_fwupgrade
>    ```

> [!tip] Способ 2 — вручную
> Скопировать содержимое файла и вставить в терминал RouterOS целиком.

---

## Проверка установки

```routeros
/system scheduler print where name=routerboard_fwupgrade
/system routerboard print
```

В выводе `/system routerboard print` сравни **`current-firmware`** и **`upgrade-firmware`**: если различаются — есть что обновлять.

---

## Ручной запуск / тест

> [!danger] У scheduler нет команды `run`
> `/system scheduler run ...` выдаёт `bad command name run` — это нормально, такой команды не существует. Логику запускают иначе.

Проверить и при необходимости обновиться прямо сейчас (с авто-ребутом):

```routeros
:if ([/system routerboard get current-firmware] != [/system routerboard get upgrade-firmware]) do={ :put "upgrade needed"; /system routerboard upgrade; :delay 15s; /system reboot } else={ :put "firmware is up to date" }
```

Или по шагам, без немедленной перезагрузки:

```routeros
/system routerboard upgrade   ;# применится при следующей перезагрузке
/system reboot                ;# когда можно перезагрузить
```

---

## Логи

```routeros
/log print where message~"routerboard_fwupgrade"
```

> [!success] Что увидишь
> - `new firmware available, upgrading...` → `firmware applied, rebooting now`, либо
> - `firmware is up to date`.

---

## Как это работает

> [!note] Когда срабатывает
> Scheduler стоит на `start-time=startup` — отрабатывает при каждой загрузке. Зацикливания нет: после применения прошивки `current-firmware == upgrade-firmware`, и условие больше не выполняется.

Типичный сценарий: обновил RouterOS → роутер перезагрузился → на старте scheduler подтянул и прошивку RouterBOARD.

---

## Связанные заметки

- [[cloudflare-ip-updater-obsidian|CloudFlare IP Updater]]
- [[initial-setup]] — базовая настройка RouterOS
