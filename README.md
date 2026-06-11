# scripts

Коллекция скриптов для администрирования серверов: PostgreSQL для 1С, Windows-инфраструктура (1С, RD Gateway), мониторинг Zabbix.

## Структура

```
windows/   PowerShell-скрипты для Windows
pgsql/     PostgreSQL: установка, бэкапы, отказоустойчивость
linux/     Linux: тесты железа, конфиги окружения
zabbix/    Шаблоны Zabbix
```

## windows/

| Скрипт | Назначение |
|---|---|
| `1CDefenderExclusion.ps1` | Добавляет исключения 1С в Windows Defender: каталоги платформы и файловых баз (из `ibases.v8i` всех профилей), расширения и процессы. Запуск от администратора. |
| `Replace-1C-Ibases.ps1` | Раздаёт эталонный `ibases.v8i` (список баз 1С) пользователям группы `1C_all` с бэкапом старых файлов. Интерактивный выбор пользователей. |
| `Update-RDGWCertificate.ps1` | Получение/продление сертификата Let's Encrypt через Posh-ACME (DNS-плагин Beget) и установка на RD Gateway. Для планировщика: одно задание раз в сутки с наивысшими правами. Сохранять в UTF-8 with BOM. |

## pgsql/

| Скрипт | Назначение |
|---|---|
| `pg_setup.sh` | Установка и первичная настройка Postgres Pro 1C на Debian/Ubuntu: локали, часовой пояс, репозиторий, initdb с `--tune=1c`, pg_hba, пароль postgres. Параметры: `--pgver`, `--timezone`, `--lang`, `--postgres-pass`. Запуск от root. |
| `backup-db-1c.sh` | Бэкап (pg_dump + pigz) и обслуживание (vacuumdb/reindexdb) баз Postgres Pro 1C по списку из файла. Ротация старых копий. Для cron. |
| `backup-db-pgsql.sh` | То же для ванильного PostgreSQL (бинарники из `/usr/bin`). |

Зависимости бэкап-скриптов: `pigz`. Список баз — текстовый файл (по умолчанию `/var/lib/pgpro/scripts/DB`), по одной базе на строку.

### pgsql/failover/

Связка keepalived + потоковая репликация PostgreSQL на два узла (active/standby с VIP).

| Файл | Назначение |
|---|---|
| `keepalived.conf` | Конфиг keepalived: VIP, проверка живости PostgreSQL, вызов promote при переходе в MASTER. |
| `check-pg-alive.sh` | Проверка `pg_isready` для vrrp_script. |
| `promote-standby.sh` | Повышение реплики до мастера (вызывается keepalived через `notify_master`). |
| `rejoin-replica.sh` | При старте узла: если второй узел — живой мастер, пересоздаёт себя как реплику через `pg_basebackup`; иначе повышается до мастера. |

> ⚠️ Перед использованием замените в конфигах и скриптах IP-адреса, пароль keepalived и учётные данные репликации на свои (пароль репликации — через `~postgres/.pgpass`, права 600).

## linux/

| Файл | Назначение |
|---|---|
| `nvme_test.sh` | Тест NVMe-диска через fio по профилю CrystalDiskMark (SEQ1M Q8T1, SEQ128K Q32T1, RND4K Q32T8, RND4K Q1T1). Зависимости: `fio`, `jq`. |
| `configs/.bashrc`, `configs/.bash_aliases` | Окружение bash для серверов. |
| `configs/commands.list` | Шпаргалка команд Linux по разделам (процессы, мониторинг, сеть и т.д.). |

## zabbix/

| Файл | Назначение |
|---|---|
| `zbx_export_templates.yaml` | Шаблон «Windows hardware by Zabbix agent active»: температуры, SMART, кулеры, напряжения. Требует smartmontools, OpenHardwareMonitor и скрипты `windows.hard.ps1` / `windows.hdd.ps1` на хосте. |

## CI

GitHub Actions прогоняет линтеры на каждый push и pull request:

- **shellcheck** для всех `*.sh` (порог — ошибки);
- **PSScriptAnalyzer** для всех `*.ps1` (порог — ошибки).
