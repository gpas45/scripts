---
title: Backup & Update — автоматический бэкап и обновление RouterOS
tags:
  - mikrotik
  - routeros
  - backup
  - update
  - email
  - script
created: 2026-06-13
aliases:
  - BackupAndUpdate
  - BackupAndUpdate.rsc
  - backup-and-update
---

# Backup & Update — автоматический бэкап и обновление RouterOS

Скрипт [[BackupAndUpdate]] (`routeros/BackupAndUpdate.rsc`) создаёт ежедневные резервные копии MikroTik (полный системный бэкап `.backup` + экспорт конфигурации `.rsc`) и отправляет их на e-mail. Дополнительно умеет уведомлять о новых версиях RouterOS и автоматически их устанавливать вместе с обновлением прошивки RouterBOARD.

> [!info] Назначение
> Использовать почтовый ящик как хранилище бэкапов и держать прошивку в актуальном состоянии без ручного вмешательства. Перед автообновлением всегда снимается резервная копия, а сам апдейт отменяется, если бэкап не удалось отправить письмом.

- **Версия скрипта:** `26.02.22`
- **Автор:** Alexander Tebiev ([github.com/beeyev](https://github.com/beeyev/Mikrotik-RouterOS-automatic-backup-and-update))
- **Минимальная поддерживаемая RouterOS:** v6.43.7
- **Лицензия:** MIT

## Возможности

- Три режима работы под разные сценарии (см. ниже).
- Полный системный бэкап и экспорт конфигурации в одном запуске.
- Выбор канала обновлений: `stable`, `long-term`, `testing`, `development`.
- Режим «только патчи»: например, с v6.43.6 обновится на v6.43.7 (патч), но пропустит v6.44.0 (минорное обновление). Работает только для каналов `stable` и `long-term`.
- В письмо включается информация об устройстве (имя, модель, серийный номер, версия ОС, uptime, публичный IP) — удобно различать бэкапы нескольких роутеров.
- Безопасность: автообновление останавливается, если бэкап не удалось отправить по почте.
- Прошивка RouterBOARD обновляется автоматически после обновления RouterOS.

## Режимы работы (`scriptMode`)

| Значение | Поведение |
|---|---|
| `backup` | Только бэкап: система + конфиг отправляются на e-mail вложением. Значение по умолчанию. |
| `osnotify` | Бэкап + проверка наличия новой версии RouterOS, уведомление письмом (без установки). |
| `osupdate` | Бэкап → проверка обновлений → установка новой версии. Шлёт два письма: с бэкапами старой версии (до апдейта) и новой (после). |

> [!tip] Логика в три шага
> При автообновлении скрипт переживает перезагрузки, сохраняя состояние через глобальные переменные и временную задачу планировщика `BKPUPD-NEXT-BOOT-TASK`:
> 1. **Шаг 1** — бэкап до обновления, запуск установки RouterOS, перезагрузка.
> 2. **Шаг 2** — обновление прошивки RouterBOARD, вторая перезагрузка (пропускается на CHR/x86).
> 3. **Шаг 3** — финальный бэкап обновлённой системы и итоговый отчёт на почту.

## Установка

> [!warning] Важно
> Имя устройства (`System -> Identity`) не должно содержать пробелов и спецсимволов.

### 1. Настройте параметры

Откройте `routeros/BackupAndUpdate.rsc` и заполните секцию `--- MODIFY THIS SECTION AS NEEDED ---` в начале файла. Все параметры подробно прокомментированы.

> [!important]
> Обязательно укажите корректный `emailAddress` и проверьте значение `scriptMode`.

Ключевые параметры:

| Параметр | Назначение |
|---|---|
| `emailAddress` | Адрес для отправки бэкапов и уведомлений. |
| `scriptMode` | Режим: `backup` / `osnotify` / `osupdate`. |
| `forceBackup` | Делать бэкап при каждом запуске, независимо от режима. |
| `backupPassword` | Пароль шифрования бэкапа (пусто — без шифрования). |
| `sensitiveDataInConfig` | Включать пароли в экспорт конфигурации. |
| `updateChannel` | Канал обновлений: `stable` / `long-term` / `testing` / `development`. |
| `installOnlyPatchUpdates` | Ставить только патч-обновления (для `stable`/`long-term`). |
| `detectPublicIpAddress` | Добавлять публичный IP в письмо. |
| `anonStats` | Анонимная статистика автору скрипта. Поставьте `false`, если не нужно. |

### 2. Создайте скрипт

`System -> Scripts [Add]`

> [!important]
> Имя скрипта должно быть точно `BackupAndUpdate`.

Вставьте настроенный код в поле source.

![[howto/script-name.png]]

### 3. Настройте почтовый сервер

`Tools -> Email` — задайте параметры SMTP. Если своего сервера нет, подойдёт бесплатный тариф [smtp2go.com](https://smtp2go.com) (до 1000 писем в месяц).

![[howto/email-config.png]]

Проверка отправки тестовым письмом из терминала:

```
/tool e-mail send to="yourMail@example.com" subject="backup & update test!" body="It works!";
```

### 4. Создайте задачу в планировщике

`System -> Scheduler [Add]`

- **Name:** `Backup And Update`
- **Start Time:** `03:10:00` (для разных роутеров в цепочке время должно отличаться)
- **Interval:** `1d 00:00:00`
- **On Event:** `/system script run BackupAndUpdate;`

![[howto/scheduler-task.png]]

Либо одной командой:

```
/system scheduler add name="Firmware Updater" on-event="/system script run BackupAndUpdate;" start-time=03:10:00 interval=1d comment="" disabled=no
```

### 5. Проверьте работу

Откройте Terminal и окно Log в WinBox и запустите вручную:

```
/system script run BackupAndUpdate;
```

Следите за выполнением в логе. Если ошибок нет — на почте появится письмо с бэкапами роутера. 🎉

## Связанные материалы

- [[routerboard-fwupgrade-obsidian|RouterBOARD firmware upgrade]] — отдельная задача автообновления прошивки.
- [[initial-setup-obsidian|initial-setup]] — расширенный шаблон настройки роутера.

> [!note] Источник
> Скрипт основан на проекте [beeyev/Mikrotik-RouterOS-automatic-backup-and-update](https://github.com/beeyev/Mikrotik-RouterOS-automatic-backup-and-update) (лицензия MIT).
