#!/bin/bash

# Поднятие инстанса в статусе мастера
# Путь к логу
LOG="/var/log/postgresql/promote.log"
mkdir -p /var/log/postgresql
exec >> "$LOG" 2>&1
echo "$(date): Starting promotion process..."

# Проверяем, не мастер ли мы уже (если НЕ в recovery — значит, уже мастер)
if sudo -u postgres psql -tAc "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q "f"; then
    echo "$(date): Already master, nothing to do."
    exit 0
fi

# Проверяем, что мы в режиме восстановления (реплика)
if ! sudo -u postgres psql -tAc "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q "t"; then
    echo "$(date): Not in recovery mode — cannot promote (not a replica)."
    exit 1
fi

# Дополнительно: проверим, есть ли standby.signal (опционально, но полезно)
STANDBY_SIGNAL="/var/lib/pgpro/std-12/data/standby.signal"
if [ ! -f "$STANDBY_SIGNAL" ]; then
    echo "$(date): Warning: standby.signal not found. Promotion will still proceed if in recovery."
fi

# Запускаем promote
echo "$(date): Promoting to master..."
sudo -u postgres pg_ctl promote -D /var/lib/pgpro/std-12/data

# Ждём 3 секунды — promote обычно синхронный, но даём время
sleep 3

# Проверяем результат
if sudo -u postgres psql -tAc "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q "f"; then
    echo "$(date): Promotion successful — server is now master."
    exit 0
else
    echo "$(date): Promotion failed — still in recovery or PostgreSQL unreachable."
    exit 1
fi
