# pgsql/

PostgreSQL / Postgres Pro для 1С: установка, бэкапы, отказоустойчивость.

| Скрипт | Назначение |
|---|---|
| `pg_setup.sh` | Установка и первичная настройка Postgres Pro 1C на Debian/Ubuntu: локали, часовой пояс, репозиторий, initdb с `--tune=1c`, pg_hba, пароль postgres. Параметры: `--pgver`, `--timezone`, `--lang`, `--postgres-pass`. Запуск от root. |
| `backup-db.sh` | Бэкап (pg_dump + pigz, с проверкой целостности архива) и обслуживание (vacuumdb) баз PostgreSQL / Postgres Pro по списку из файла. Ротация бэкапов отдельно по каждой БД, логов — по возрасту. Для cron. |
| `backup-pg.conf.example` | Пример конфига для `backup-db.sh` (копируется в `/etc/backup-pg.conf`): пути, retention, каталог бинарников. |
| `pg-status/` | Go-утилита: состояние экземпляров (кластеров) PostgreSQL / Postgres Pro — запущен/остановлен, порт, каталог и его размер, суммарный вес и список баз, аптайм, соединения, cache hit, commit/rollback. Read-only. См. `pg-status/README.md`. |
| `pgpro/` | Рабочие скрипты Postgres Pro, перенесённые «как есть» с боевых серверов: wal-g, pg_probackup, обслуживание, добавление кластера, systemd-таймер. См. `pgpro/README.md`. |

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
