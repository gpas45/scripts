#!/bin/bash

# Делает из текущего инстанса реплику
set -euo pipefail

# === НАСТРОЙКИ ===
LOG="/var/log/postgresql/rejoin.log"
DATA_DIR="/var/lib/pgpro/std-12/data"
PEER_IP="195.117.117.32"       # IP предполагаемого мастера 32/31 в зависимости от того на какой ноде висит скрипт
REPL_USER="replicator"
PASSWORD="replicate"
PORT="5432"

MAX_ATTEMPTS=3
RETRY_DELAY=5
STARTUP_TIMEOUT=20
ROLE_CHECK_ATTEMPTS=5
ROLE_CHECK_DELAY=5


sleep 100 # указывается для второго сервера, что бы не допустить одновременного поднятия двух мастеров  

# === ПОДГОТОВКА ЛОГОВ ===
mkdir -p "$(dirname "$LOG")"
chown postgres:postgres "$(dirname "$LOG")" || true
chmod 755 "$(dirname "$LOG")" || true
exec >> "$LOG" 2>&1
echo "[$(date)] === STARTING SMART REJOIN ==="

# === ФУНКЦИЯ: ПРОВЕРКА, ЯВЛЯЕТСЯ ЛИ УЗЕЛ МАСТЕРОМ ===
is_master() {
    local ip=$1
    if runuser -l postgres -c "
        export PGPASSWORD='$PASSWORD';
        psql -h '$ip' -U '$REPL_USER' -p '$PORT' -d 'postgres' -Atc 'SELECT pg_is_in_recovery();'
    " 2>/dev/null | grep -q "^f$"; then
        return 0  # Это мастер
    else
        return 1  # Не мастер (реплика или недоступен)
    fi
}

# === ФУНКЦИЯ: ПРОВЕРКА, ЗАПУЩЕН ЛИ ЛОКАЛЬНЫЙ ПОСТГРЕС ===
is_local_postgres_running() {
    pg_ctl -D "$DATA_DIR" status &>/dev/null
}

# === ФУНКЦИЯ: ОСТАНОВКА ЛОКАЛЬНОГО ПОСТГРЕСА ===
stop_postgres() {
    echo "[$(date)] Stopping PostgreSQL..."
    if is_local_postgres_running; then
        runuser -l postgres -c "pg_ctl -D '$DATA_DIR' stop -m fast"
    fi
}

# === ФУНКЦИЯ: ЗАПУСК ПОСТГРЕСА (КАК РЕПЛИКА) ===
start_postgres() {
    echo "[$(date)] Starting PostgreSQL..."
    if ! is_local_postgres_running; then
        runuser -l postgres -c "pg_ctl -D '$DATA_DIR' start"
    fi
}

# === ФУНКЦИЯ: ПОВЫШЕНИЕ ДО МАСТЕРА ===
promote_to_master() {
    echo "[$(date)] Promoting to master..."

    # Убедимся, что PostgreSQL запущен
    start_postgres

    # Проверяем, в режиме ли recovery (т.е. реплика)
    if runuser -l postgres -c "psql -tAc 'SELECT pg_is_in_recovery();'" 2>/dev/null | grep -q "^t$"; then
        runuser -l postgres -c "pg_ctl promote -D '$DATA_DIR'"
        sleep 3
        if runuser -l postgres -c "psql -tAc 'SELECT pg_is_in_recovery();'" 2>/dev/null | grep -q "^f$"; then
            echo "[$(date)] Promotion successful — now master."
        else
            echo "[$(date)] Promotion failed or still in recovery."
            exit 1
        fi
    elif runuser -l postgres -c "psql -tAc 'SELECT pg_is_in_recovery();'" 2>/dev/null | grep -q "^f$"; then
        echo "[$(date)] Already master, nothing to do."
    else
        echo "[$(date)] PostgreSQL is unreachable."
        exit 1
    fi
}

# === ФУНКЦИЯ: СТАТЬ РЕПЛИКОЙ ===
become_replica() {
    echo "[$(date)] Master $PEER_IP is alive and is master. Becoming replica..."

    stop_postgres

    echo "[$(date)] Cleaning old data directory..."
    rm -rf "$DATA_DIR"
    mkdir -p "$DATA_DIR"
    chown postgres:postgres "$DATA_DIR"
    chmod 700 "$DATA_DIR"

    echo "[$(date)] Running pg_basebackup from $PEER_IP..."
    if ! runuser -l postgres -c "
        export PGPASSWORD='$PASSWORD';
        pg_basebackup \
            -h '$PEER_IP' \
            -p '$PORT' \
            -U '$REPL_USER' \
            -D '$DATA_DIR' \
            -v \
            -P \
            -R
    "; then
        echo "[$(date)] pg_basebackup failed!"
        exit 1
    fi
    echo "[$(date)] Base backup completed."

    # Убедимся, что standby.signal есть
    if [[ ! -f "$DATA_DIR/standby.signal" ]]; then
        echo "[$(date)] Creating standby.signal..."
        touch "$DATA_DIR/standby.signal"
        chown postgres:postgres "$DATA_DIR/standby.signal"
        chmod 600 "$DATA_DIR/standby.signal"
    fi

    start_postgres
    echo "[$(date)] Replica setup complete and PostgreSQL started."
}

# === ОСНОВНАЯ ЛОГИКА ===

# Ждём немного, чтобы сеть поднялась
sleep 15

# Проверяем, можем ли мы достучаться до мастера и является ли он мастером
echo "[$(date)] Checking master $PEER_IP status..."

if is_master "$PEER_IP"; then
    echo "[$(date)] Master $PEER_IP is alive and is master."
    become_replica
else
    echo "[$(date)] Master $PEER_IP is unreachable or not master. Promoting self to master."
    promote_to_master
fi

echo "[$(date)] === SMART REJOIN FINISHED ==="
