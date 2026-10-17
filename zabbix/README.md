# zabbix/

Шаблоны мониторинга Zabbix.

| Файл | Назначение |
|---|---|
| `zbx_export_templates.yaml` | Шаблон «Windows hardware by Zabbix agent active»: температуры, SMART, кулеры, напряжения. Требует smartmontools, OpenHardwareMonitor и скрипты `windows.hard.ps1` / `windows.hdd.ps1` на хосте. |

Мониторинг кластера 1С 8.3 через RAS/RAC — отдельный шаблон и коллектор в
[`../1c/monitoring-ras/`](../1c/monitoring-ras/).
