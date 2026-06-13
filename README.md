# scripts

Коллекция скриптов для администрирования инфраструктуры: PostgreSQL для 1С, Windows (1С, RD Gateway, развёртывание), MikroTik RouterOS, Proxmox, мониторинг Zabbix.

Сюда консолидировано содержимое репозиториев `RouterOS`, `proxmox` и `win` — теперь всё в одном месте.

## Структура

```
windows/   PowerShell-скрипты для Windows (+ oobe/ — автоустановка Windows)
pgsql/     PostgreSQL: установка, бэкапы, отказоустойчивость
routeros/  Скрипты и конфиги MikroTik RouterOS (+ docs/)
proxmox/   Скрипты для Proxmox VE
linux/     Linux: тесты железа, конфиги окружения, 1С, motd
zabbix/    Шаблоны Zabbix
```

## windows/

| Скрипт | Назначение |
|---|---|
| `1CDefenderExclusion.ps1` | Добавляет исключения 1С в Windows Defender: каталоги платформы и файловых баз (из `ibases.v8i` всех профилей), расширения и процессы. Запуск от администратора. |
| `Replace-1C-Ibases.ps1` | Раздаёт эталонный `ibases.v8i` (список баз 1С) пользователям группы `1C_all` с бэкапом старых файлов. Интерактивный выбор пользователей. |
| `Update-RDGWCertificate.ps1` | Получение/продление сертификата Let's Encrypt через Posh-ACME (DNS-плагин Beget) и установка на RD Gateway. Для планировщика: одно задание раз в сутки с наивысшими правами. Сохранять в UTF-8 with BOM. |
| `1CDefenderExclusion.bat` | Лаунчер для `1CDefenderExclusion.ps1` (запуск двойным кликом). |

### windows/oobe/

Автоматизация чистой установки Windows.

| Файл | Назначение |
|---|---|
| `AutoUnattend.xml` | Файл ответов для автоустановки Windows: локали, пропуск сетевой настройки, создание локального администратора `Admin`. |
| `oobe.ps1` | Автоматизация этапа OOBE через скачивание файла ответов. |

> ⚠️ Создаётся локальный администратор `Admin/Admin` — сразу после установки смените пароль. Заглушки `CHANGE_ME` в конфиге замените своими значениями.

## pgsql/

| Скрипт | Назначение |
|---|---|
| `pg_setup.sh` | Установка и первичная настройка Postgres Pro 1C на Debian/Ubuntu: локали, часовой пояс, репозиторий, initdb с `--tune=1c`, pg_hba, пароль postgres. Параметры: `--pgver`, `--timezone`, `--lang`, `--postgres-pass`. Запуск от root. |
| `backup-db.sh` | Бэкап (pg_dump + pigz, с проверкой целостности архива) и обслуживание (vacuumdb) баз PostgreSQL / Postgres Pro по списку из файла. Ротация бэкапов отдельно по каждой БД, логов — по возрасту. Для cron. |
| `backup-pg.conf.example` | Пример конфига для `backup-db.sh` (копируется в `/etc/backup-pg.conf`): пути, retention, каталог бинарников. |
| `pgpro/` | Рабочие скрипты Postgres Pro, перенесённые «как есть» с боевых серверов: wal-g, pg_probackup, обслуживание, добавление кластера, systemd-таймер. См. `pgsql/pgpro/README.md`. |

Зависимости `backup-db.sh`: `pigz`. Список баз — текстовый файл (по умолчанию `/var/lib/pgpro/scripts/DB`), по одной базе на строку, `#` — комментарий.

### pgsql/failover/

Связка keepalived + потоковая репликация PostgreSQL на два узла (active/standby с VIP).

| Файл | Назначение |
|---|---|
| `keepalived.conf` | Конфиг keepalived: VIP, проверка живости PostgreSQL, вызов promote при переходе в MASTER. |
| `check-pg-alive.sh` | Проверка `pg_isready` для vrrp_script. |
| `promote-standby.sh` | Повышение реплики до мастера (вызывается keepalived через `notify_master`). |
| `rejoin-replica.sh` | При старте узла: если второй узел — живой мастер, пересоздаёт себя как реплику через `pg_basebackup`; иначе повышается до мастера. |

> ⚠️ Перед использованием замените в конфигах и скриптах IP-адреса (указаны примеры из 192.0.2.0/24) и пароль keepalived на свои. Пароль репликации в скриптах не хранится — создайте `~postgres/.pgpass` (права 600) со строкой `<IP второго узла>:5432:*:replicator:<пароль>`.

## routeros/

Скрипты и конфиги для MikroTik RouterOS.

| Файл | Назначение |
|---|---|
| `autorun.rsc` | Шаблон первичной настройки роутера: адресация, отключение небезопасных сервисов (telnet, ftp, api и т.д.), NTP, часовой пояс. Замените `CHANGE_ME` на свои значения. |
| `initial-setup.rsc` | Расширенный шаблон настройки: bridge, interface-lists (WAN/LAN/StS/VPN), полный firewall (port knocking, anti-bruteforce, ICMP), NAT, DNS, харднинг сервисов, OSPF-фильтры, автообновление прошивки. |
| `check-isp.rsc` | Проверка доступности двух провайдеров пингом и сброс соединений упавшего канала (для dual-WAN). |
| `cloudflare-ip-updater.rsc` | Обновление address-list `CF` актуальными IPv4-подсетями Cloudflare (по расписанию). |
| `telegram-ip-updater.rsc` | Обновление address-list `TG` актуальными IPv4-подсетями Telegram (по расписанию). |
| `google-ip-updater.rsc` | Обновление address-list `VPN_ytb` актуальными IPv4-диапазонами Google (goog.json) — для policy-routing на Google/YouTube (по расписанию). |
| `ospf_filter_rules` | Фильтры OSPF: принимать только частные подсети (RFC 1918). |
| `routerboard_fwupgrade` | Задание планировщика: автообновление прошивки RouterBOARD с перезагрузкой. |
| `routerboard_starwars` | Имперский марш на системном динамике после загрузки. |
| `BackupAndUpdate.rsc` | Автоматический бэкап MikroTik (система + конфиг) с отправкой на e-mail, уведомления о новых версиях RouterOS и автообновление прошивки RouterOS/RouterBOARD. Версия 26.02.22. |
| `docs/` | Obsidian-документация по установке каждого скрипта (`*-obsidian.md`), скриншоты-инструкции (`howto/`), чек-лист настройки роутера, продуктовая матрица MikroTik. |

## proxmox/

| Скрипт | Назначение |
|---|---|
| `chr_install.sh` | Развёртывание VM с MikroTik CHR на Proxmox VE: скачивание образа нужной версии, создание диска и виртуальной машины. Интерактивный. |

## linux/

| Файл | Назначение |
|---|---|
| `nvme_test.sh` | Тест NVMe-диска через fio по профилю CrystalDiskMark (SEQ1M Q8T1, SEQ128K Q32T1, RND4K Q32T8, RND4K Q1T1). Зависимости: `fio`, `jq`. |
| `setup-unattended-upgrades.sh` | Настройка автоматических обновлений безопасности (unattended-upgrades) на Debian/Ubuntu. |
| `1c/1c_full_upgrade.sh` | Полное обновление платформы 1С:Предприятие на Linux (скачивание, установка, переключение версии). |
| `1c/1c_web_apache.sh` | Публикация баз 1С на веб-сервере Apache. Интерактивный (запрашивает версию платформы). |
| `motd/` | Баннеры motd для серверов (1С, PostgreSQL, Proxmox) + генератор `99-mymotd-generator`. |
| `configs/.bashrc`, `configs/.bash_aliases` | Окружение bash для серверов. |
| `configs/commands.list` | Шпаргалка команд Linux по разделам (процессы, мониторинг, сеть и т.д.). |

## zabbix/

| Файл | Назначение |
|---|---|
| `zbx_export_templates.yaml` | Шаблон «Windows hardware by Zabbix agent active»: температуры, SMART, кулеры, напряжения. Требует smartmontools, OpenHardwareMonitor и скрипты `windows.hard.ps1` / `windows.hdd.ps1` на хосте. |

## CI

GitHub Actions прогоняет линтеры на каждый push и pull request:

- **shellcheck** для всех `*.sh` (порог — предупреждения);
- **PSScriptAnalyzer** для всех `*.ps1` (порог — ошибки).
