# scripts

Коллекция скриптов для администрирования инфраструктуры: PostgreSQL для 1С, Windows (1С, RD Gateway, развёртывание), MikroTik RouterOS, Proxmox, мониторинг Zabbix.

Сюда консолидировано содержимое репозиториев `RouterOS`, `proxmox` и `win` — теперь всё в одном месте.

## Разделы

Описание конкретных файлов вынесено в `README.md` внутри каждой папки — открывайте нужный раздел.

| Папка | Содержимое |
|---|---|
| [`windows/`](windows/) | PowerShell-скрипты для Windows (1С, RD Gateway) + `oobe/` — автоустановка Windows. |
| [`pgsql/`](pgsql/) | PostgreSQL / Postgres Pro: установка, бэкапы, отказоустойчивость (`failover/`, `pgpro/`). |
| [`routeros/`](routeros/) | Скрипты и конфиги MikroTik RouterOS + `docs/` (Obsidian-документация). |
| [`proxmox/`](proxmox/) | Скрипты для Proxmox VE. |
| [`linux/`](linux/) | Linux: тесты железа, конфиги окружения, 1С, motd. |
| [`zabbix/`](zabbix/) | Шаблоны мониторинга Zabbix. |
| [`obsidian/`](obsidian/) | Шаблоны Obsidian (Templater), напр. торговый дневник. |

## CI

GitHub Actions прогоняет линтеры на каждый push и pull request:

- **shellcheck** для всех `*.sh` (порог — предупреждения);
- **PSScriptAnalyzer** для всех `*.ps1` (порог — ошибки).
