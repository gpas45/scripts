# pg-status

Read-only утилита на Go: показывает состояние экземпляров (кластеров)
PostgreSQL / Postgres Pro на хосте. Ничего не меняет.

Понимает обе схемы размещения:

- **Postgres Pro 1C** — `postgrespro-<ver>` (default), `postgrespro-<ver>-<имя>`
  (legacy), `postgrespro-<ver>@<порт>` (штатный шаблонный юнит), сборки в
  `/opt/pgpro/<ver>`;
- **обычный PostgreSQL** — `postgresql@<ver>-<cluster>` (схема Debian/Ubuntu).

Для каждого экземпляра:

- статус systemd (запущен / остановлен / сбой) и порт;
- каталог данных (PGDATA) и его размер на диске (виден и у остановленного);
- если запущен — по данным сервера: версия, аптайм, число соединений и
  `max_connections`, суммарный вес всех БД, cache hit ratio, commit/rollback
  и список баз с размерами по убыванию (шаблонные помечены).

## Сборка

```sh
cd pgsql/pg-status
go build -o pg-status .      # только стандартная библиотека, без зависимостей
```

## Запуск

```sh
./pg-status                  # все найденные экземпляры
./pg-status 5433             # фильтр по подстроке (имя юнита / метка / порт)
./pg-status -p 5432          # прямой опрос порта, в обход systemd
./pg-status -p 5433 -bin /opt/pgpro/1c-18/bin
./pg-status --no-color       # без ANSI-цвета (авто-выключается вне терминала и при NO_COLOR)
```

Статистика БД собирается через `psql` с peer-аутентификацией от пользователя
`postgres`, поэтому запускать нужно **от root** (использует `runuser`/`sudo`
для перехода в `postgres`) **или от самого `postgres`**. Информация из systemd и
размер каталога на диске доступны и без этих прав.

## Пример вывода

```
Состояние PostgreSQL / Postgres Pro   2026-07-12 14:20:01

Postgres Pro 1c-18  (postgrespro-1c-18@5433)
  Статус:        ● запущен   порт 5433
  Каталог:       /var/lib/pgpro/1c-18/data-5433
  Размер на ФС:  5.1GiB
  Версия:        17.4
  Аптайм:        1д 2ч 3м
  Соединения:    12 / 100   (активных запросов: 3)
  Суммарно БД:   5.0GiB
  Cache hit:     99.7%   commit: 123456   rollback: 42
  База                                   Размер
  buh                                    3.0GiB
  zup                                    1.9GiB
  postgres                               8.0MiB
  template1                              7.0MiB (шаблон)
```

## Зависимости

`systemctl`, `ss` (iproute2), `du`, `psql`. Порт определяется по слушающему
сокету postmaster, затем `postgresql.conf`, затем `PGPORT` из systemd.
