# pgsql/

PostgreSQL / Postgres Pro для 1С: установка, бэкапы, отказоустойчивость.

| Скрипт | Назначение |
|---|---|
| `pg-server-manager.sh` | Интерактивный менеджер Postgres Pro 1C для Debian/Ubuntu (whiptail/dialog TUI с откатом в консоль): базовая настройка ОС (локали, TZ, консоль), установка/удаление разных релизов (`1c-16`/`1c-17`/`1c-18` параллельно в `/opt/pgpro/<ver>`), управление несколькими экземплярами (кластерами) — создать/удалить/старт/стоп/статус, порт, пароль postgres, внешний доступ, IPv6, MOTD-баннер. Запуск от root. |
| `INSTALL-pgpro-1c.md` | Ручная пошаговая установка Postgres Pro 1C в LXC (Debian 13) — эквивалент `pg-server-manager.sh` в виде копируемых команд: ОС, релиз, дефолтный и дополнительный кластеры, пароль/`.pgpass`/pg_hba, firewall. |
| `backup-db.sh` | Бэкап (pg_dump + pigz, с проверкой целостности архива) и обслуживание (vacuumdb) баз PostgreSQL / Postgres Pro по списку из файла. Ротация бэкапов отдельно по каждой БД, логов — по возрасту. Для cron. |
| `backup-pg.conf.example` | Пример конфига для `backup-db.sh` (копируется в `/etc/backup-pg.conf`): пути, retention, каталог бинарников. |
| `pgpro/` | Рабочие скрипты Postgres Pro, перенесённые «как есть» с боевых серверов: wal-g, pg_probackup, обслуживание, systemd-таймер. См. `pgpro/README.md`. |

Зависимости `backup-db.sh`: `pigz`. Список баз — текстовый файл (по умолчанию `/var/lib/pgpro/scripts/DB`), по одной базе на строку, `#` — комментарий.

## failover/

Связка keepalived + потоковая репликация PostgreSQL на два узла (active/standby с VIP).

| Файл | Назначение |
|---|---|
| `keepalived.conf` | Конфиг keepalived: VIP, проверка живости PostgreSQL, вызов promote при переходе в MASTER. |
| `check-pg-alive.sh` | Проверка `pg_isready` для vrrp_script. |
| `promote-standby.sh` | Повышение реплики до мастера (вызывается keepalived через `notify_master`). |
| `rejoin-replica.sh` | При старте узла: если второй узел — живой мастер, пересоздаёт себя как реплику через `pg_basebackup`; иначе повышается до мастера. |

> ⚠️ Перед использованием замените в конфигах и скриптах IP-адреса (указаны примеры из 192.0.2.0/24) и пароль keepalived на свои. Пароль репликации в скриптах не хранится — создайте `~postgres/.pgpass` (права 600) со строкой `<IP второго узла>:5432:*:replicator:<пароль>`.
