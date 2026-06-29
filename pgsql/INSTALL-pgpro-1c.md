# Ручная установка Postgres Pro 1C в LXC (Debian 13)

Пошаговый эквивалент того, что делает [`pg-server-manager.sh`](pg-server-manager.sh).
Все команды — от **root**. Переменная версии задаётся один раз:

```bash
export PGVER='1c-18'        # линейка 1C: 1c-16 / 1c-17 / 1c-18
```

> ⚠️ **`PGVER` (а в разделе 5 ещё `PORT`/`DDIR`/`UNIT`/`DEFDIR`) живут только в текущей сессии.**
> После нового SSH-подключения или `su` задайте их заново — иначе пути соберутся пустыми
> (`/opt/pgpro//bin/…`). В начале каждого раздела стоит проверка `: "${PGVER:?…}"`,
> которая сразу подскажет, если переменная не задана.

> В LXC скрипт работает без `sudo` (его часто нет): команды от пользователя `postgres`
> запускаются через `runuser -u postgres -- …`. Ниже используется тот же приём.

---

## 1. Базовая настройка ОС

### Пакеты
```bash
apt-get update -y
apt-get -o Dpkg::Options::=--force-confnew dist-upgrade -y
apt-get install -y mc nano console-setup net-tools htop \
                   curl ca-certificates gnupg lsb-release locales sudo tzdata
```

### Локали — ОБЕ обязательны
`ru_RU.UTF-8` нужна для `initdb` кластера, `en_US.UTF-8` — для `lc_messages` (журналы на английском).
```bash
sed -i 's/^# *\(ru_RU.UTF-8 UTF-8\)/\1/; s/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
grep -qxF "ru_RU.UTF-8 UTF-8" /etc/locale.gen || echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen
grep -qxF "en_US.UTF-8 UTF-8" /etc/locale.gen || echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
update-locale LANG=ru_RU.UTF-8 LC_ALL=ru_RU.UTF-8
```

### Часовой пояс и консоль
```bash
timedatectl set-timezone "Asia/Yekaterinburg" || {
    ln -sf /usr/share/zoneinfo/Asia/Yekaterinburg /etc/localtime
    echo "Asia/Yekaterinburg" > /etc/timezone
    dpkg-reconfigure -f noninteractive tzdata
}
cat > /etc/default/console-setup <<'EOF'
ACTIVE_CONSOLES="/dev/tty[1-6]"
CHARMAP="UTF-8"
CODESET="guess"
FONTFACE="TerminusBold"
FONTSIZE="8x16"
EOF
setupcon --force || true   # в LXC возможны «Не удалось открыть /dev/ttyN» — это нормально
```
> В LXC у контейнера нет VT-консолей, поэтому `setupcon` пишет «Не удалось открыть /dev/tty…» —
> сообщения безобидны (шрифт консоли в контейнере и не нужен), шаг некритичен.

### Отключение IPv6 (опционально)
Применяем **только свой файл** — `sysctl --system` в LXC падает на чужих ключах.
```bash
cat > /etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
# Отключение IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sysctl -p /etc/sysctl.d/99-disable-ipv6.conf || \
  echo "В LXC применение sysctl может быть ограничено хостом — настройка останется в конфиге."
```

---

## 2. Установка релиза Postgres Pro

### Репозиторий
`pgpro-repo-add.sh` завершается кодом **2**, если репозиторий уже добавлен — это **не ошибка**.
```bash
: "${PGVER:?задайте: export PGVER=1c-18}"
curl -fsSL "https://repo.postgrespro.ru/$PGVER/keys/pgpro-repo-add.sh" -o /tmp/pgpro-repo-add.sh
bash /tmp/pgpro-repo-add.sh || true     # код 2 = «уже добавлен»
apt-get update -y
apt-get install -y postgrespro-$PGVER
```

### Симлинки клиентских/серверных программ
```bash
/opt/pgpro/$PGVER/bin/pg-wrapper links update
```

### Фиксация версий (чтобы apt их не обновлял)
```bash
apt-mark hold postgrespro-$PGVER postgrespro-$PGVER-server postgrespro-$PGVER-client \
              postgrespro-$PGVER-contrib postgrespro-$PGVER-libs \
              postgresql-common postgresql-client-common libpq5
```
> Для обновления: `apt-mark unhold …` (те же пакеты) → `apt-get update && apt-get install --only-upgrade postgrespro-$PGVER` → при желании снова `hold`.

Проверка установки: должен существовать `/opt/pgpro/$PGVER/bin/postgres`.

---

## 3. Дефолтный кластер

Пакет `postgrespro-$PGVER` обычно **уже создаёт** дефолтный кластер в `/var/lib/pgpro/$PGVER/data`.
Чтобы инициализировать его с тюнингом 1С заново, сначала остановите и очистите каталог
(**все данные кластера будут удалены**):

```bash
: "${PGVER:?задайте: export PGVER=1c-18}"
DDIR="/var/lib/pgpro/$PGVER/data"
systemctl stop postgrespro-$PGVER 2>/dev/null || true
rm -rf "$DDIR"
/opt/pgpro/$PGVER/bin/pg-setup initdb --tune=1c --locale=ru_RU.UTF-8
```

### Журналирование (файлы в `log/`, сообщения на английском)
```bash
cat >> "$DDIR/postgresql.conf" <<'EOF'

# Журналы: сбор в файлы, каталог log/, сообщения на английском
logging_collector = on
log_directory = 'log'
lc_messages = 'en_US.UTF-8'
EOF
```

### Контрольные суммы страниц — ДО запуска кластера
Для PG 10–16 включаются отдельно; на PG 17/18 уже включены при `initdb` — тогда команда не нужна.
Безопасная проверка перед включением:
```bash
: "${PGVER:?задайте: export PGVER=1c-18}"; : "${DDIR:?задайте: DDIR=/var/lib/pgpro/$PGVER/data}"
if ! /opt/pgpro/$PGVER/bin/pg_controldata "$DDIR" | grep -qE 'Data page checksum version:[[:space:]]*[1-9]'; then
    runuser -u postgres -- /opt/pgpro/$PGVER/bin/pg_checksums --enable -D "$DDIR"
fi
```

### Автозапуск и старт
```bash
systemctl enable postgrespro-$PGVER
systemctl start  postgrespro-$PGVER
systemctl status postgrespro-$PGVER --no-pager
```

---

## 4. Пароль postgres, `.pgpass` и pg_hba

### Пароль (через stdin, не светится в `ps`)
```bash
: "${PGVER:?задайте: export PGVER=1c-18}"
PASS='ВАШ_ПАРОЛЬ'; PORT=5432
printf "ALTER USER postgres WITH PASSWORD '%s';\n" "$PASS" \
  | runuser -u postgres -- /opt/pgpro/$PGVER/bin/psql -v ON_ERROR_STOP=1 -p "$PORT" -d postgres -f -
```

### `~/.pgpass` (для беспарольного psql)
Привязка к порту, `database = *`, две записи; права `600`.
```bash
PGPASS="$HOME/.pgpass"; touch "$PGPASS"; chmod 600 "$PGPASS"
sed -i "/^localhost:$PORT:/d; /^127\.0\.0\.1:$PORT:/d" "$PGPASS"
printf 'localhost:%s:*:postgres:%s\n127.0.0.1:%s:*:postgres:%s\n' "$PORT" "$PASS" "$PORT" "$PASS" >> "$PGPASS"
chmod 600 "$PGPASS"
```

### pg_hba.conf — парольная аутентификация локальных подключений
`scram-sha-256` для PG ≥ 14, `md5` для PG ≤ 13 (совпадает с форматом хранения пароля).
```bash
HBA="$DDIR/pg_hba.conf"
METHOD=scram-sha-256        # для PG ≤ 13 → md5
sed -ri "s/^([[:space:]]*local[[:space:]]+all[[:space:]]+all[[:space:]]+)[A-Za-z0-9-]+/\1$METHOD/" "$HBA"
sed -ri "s/^([[:space:]]*local[[:space:]]+all[[:space:]]+postgres[[:space:]]+)[A-Za-z0-9-]+/\1$METHOD/" "$HBA"
systemctl reload postgrespro-$PGVER
```

---

## 5. Дополнительный экземпляр (имя = номер порта)

Несколько кластеров `pg-setup` не умеет, поэтому экземпляр собирается вручную: отдельный
каталог + копия юнита + персональный `EnvironmentFile` + drop-in. **Имя экземпляра = порт.**

> **Если пакет даёт шаблонный юнит** `postgrespro-<ver>@.service` (новые сборки PG Pro) —
> предпочтительнее штатная шаблонная схема `postgrespro-<ver>@<порт>`: каталог
> `/var/lib/pgpro/<ver>/data-<порт>`, per-instance `EnvironmentFile`
> `/etc/default/postgrespro-<ver>-<порт>` с `PGDATA=…`, и универсальный drop-in
> (`EnvironmentFile=/etc/default/postgrespro-<ver>-%I`, `Environment=PGPORT=%I`), затем
> `systemctl enable --now postgrespro-<ver>@<порт>`. `pg-server-manager.sh` выбирает эту
> схему автоматически, если шаблон есть; ниже описан запасной вариант с копией юнита.

```bash
: "${PGVER:?задайте: export PGVER=1c-18}"
export PORT=5433
export DDIR="/var/lib/pgpro/$PGVER/data-$PORT" # каталог = data-<порт> (в пару к дефолтному data)
export UNIT="postgrespro-$PGVER-$PORT"
export DEFDIR="/var/lib/pgpro/$PGVER/data"     # каталог дефолтного кластера
```

### 5.1 Инициализация кластера
```bash
mkdir -p "$DDIR"; chown -R postgres:postgres "/var/lib/pgpro/$PGVER" "$DDIR"
runuser -u postgres -- /opt/pgpro/$PGVER/bin/initdb -D "$DDIR" --locale=ru_RU.UTF-8 --data-checksums
```

### 5.2 Тюнинг 1С, журналирование и порт
```bash
mkdir -p "$DDIR/conf.d"
cat > "$DDIR/conf.d/1c.conf" <<'EOF'
max_connections = 1000
standard_conforming_strings = off
escape_string_warning = off
shared_preload_libraries = 'online_analyze, plantuner'
plantuner.fix_empty_table = on
online_analyze.enable = on
online_analyze.table_type = 'temporary'
online_analyze.verbose = off
online_analyze.local_tracking = on
online_analyze.min_interval = 10000
online_analyze.min_gain = 10
EOF
grep -q "include_dir = 'conf.d'" "$DDIR/postgresql.conf" || echo "include_dir = 'conf.d'" >> "$DDIR/postgresql.conf"
cat >> "$DDIR/postgresql.conf" <<EOF

logging_collector = on
log_directory = 'log'
lc_messages = 'en_US.UTF-8'
port = $PORT
EOF
chown -R postgres:postgres "$DDIR"
```

### 5.3 Персональный EnvironmentFile + копия юнита + drop-in
Ключевой момент: переопределяем `PGDATA`, `PGPORT` **и `PIDFile`**, а также заменяем в копии
юнита жёсткие пути дефолтного кластера — иначе экземпляр стартует с `…/data`.
```bash
cat > "/etc/default/$UNIT" <<EOF
PGDATA=$DDIR
PGPORT=$PORT
EOF

cp "/lib/systemd/system/postgrespro-$PGVER.service" "/etc/systemd/system/$UNIT.service"
sed -i \
  -e "s#/etc/default/postgrespro-$PGVER\b#/etc/default/$UNIT#g" \
  -e "s#$DEFDIR#$DDIR#g" \
  "/etc/systemd/system/$UNIT.service"

mkdir -p "/etc/systemd/system/$UNIT.service.d"
cat > "/etc/systemd/system/$UNIT.service.d/override.conf" <<EOF
[Service]
Environment=PGDATA=$DDIR
Environment=PGPORT=$PORT
PIDFile=$DDIR/postmaster.pid
EOF
systemctl daemon-reload
```

### 5.4 Запуск
```bash
systemctl enable "$UNIT"
systemctl start  "$UNIT"
systemctl status "$UNIT" --no-pager
```

### 5.5 Пароль/.pgpass/pg_hba для экземпляра
Повторите раздел 4, подставив `PORT=5433`, `DDIR=/var/lib/pgpro/$PGVER/data-5433`,
а в `systemctl reload` укажите `$UNIT`.

---

## 6. Клиент на сервере 1С
```bash
export PGVER='1c-18'
curl -fsSL "https://repo.postgrespro.ru/$PGVER/keys/pgpro-repo-add.sh" -o /tmp/pgpro-repo-add.sh
bash /tmp/pgpro-repo-add.sh || true
apt-get update -y && apt-get install -y postgrespro-$PGVER-client

# .pgpass для пользователя 1С
install -o usr1cv8 -g usr1cv8 -m 600 /dev/null /home/usr1cv8/.pgpass
echo "СЕРВЕР_БД:5432:*:postgres:ВАШ_ПАРОЛЬ" >> /home/usr1cv8/.pgpass
chmod 600 /home/usr1cv8/.pgpass
```

---

## 7. Firewall (nftables)
Разрешаем PGSQL (5432–5445) из локальной сети и SSH с доверенных адресов, остальное — drop.
```bash
nft add table inet filter
nft add chain inet filter input { type filter hook input priority 0\; }
nft add rule  inet filter input ct state related,established counter accept
nft add rule  inet filter input iifname "lo" counter accept
nft add rule  inet filter input ip protocol icmp counter accept
nft add rule  inet filter input ip saddr 192.168.1.0/24 tcp dport {5432-5445} counter accept
nft add rule  inet filter input ip saddr { 192.168.1.100/32, 192.168.1.0/24 } tcp dport 22 counter accept
nft chain     inet filter input { policy drop \; }

echo "flush ruleset" > /etc/nftables.conf
nft -s list ruleset >> /etc/nftables.conf
systemctl enable nftables.service
```

---

## Соответствие пунктам меню `pg-server-manager.sh`
| Раздел инструкции | Пункт меню скрипта |
|---|---|
| 1. Базовая настройка ОС (+IPv6) | «Базовая настройка сервера (ОС)» |
| 2. Установка релиза | «Установить релиз Postgres Pro» |
| 3. Дефолтный кластер (журналы, checksums) | часть «Установить релиз» |
| 4. Пароль / .pgpass / pg_hba | Экземпляры → «Настройка → пароль» |
| 5. Доп. экземпляр | Экземпляры → «Создать» |
| фиксация/обновление пакетов | «Разморозить пакеты (для обновления)» |
