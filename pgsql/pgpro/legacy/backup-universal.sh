#!/bin/bash
# =================================================================
# backup-universal.sh - УНИВЕРСАЛЬНЫЙ скрипт бэкапа PostgreSQL 1С
# Версия: 1.0
# Автор: По вашим требованиям
# =================================================================

# Жесткая конфигурация - ничего лишнего
export PATH=$PATH:/opt/pgpro/1c-17/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PGPASSWORD='pass'

BACKUP_DIR="/backup"
BACKUPS_DIR="/backups"
PG_HOST="127.0.0.1"
PG_PORT="5432"
PG_USER="postgres"
INSTANCE="data"
RETENTION_DAYS=20

# Автоопределение версии pg_probackup
if command -v pg_probackup-17 &>/dev/null; then
    PG_PROBACKUP="pg_probackup-17"
elif command -v pg_probackup-16 &>/dev/null; then
    PG_PROBACKUP="pg_probackup-16"
elif command -v pg_probackup-15 &>/dev/null; then
    PG_PROBACKUP="pg_probackup-15"
else
    PG_PROBACKUP="pg_probackup"
fi

# Лог
LOG_DIR="$BACKUP_DIR/log"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/backup_$(date +%Y%m%d_%H%M%S).log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# ОПРЕДЕЛЕНИЕ РЕЖИМА
CURRENT_HOUR=$(date +%H)
if [ -t 0 ]; then
    # Ручной запуск - СПРАШИВАЕМ
    echo ""
    echo "=========================================="
    echo "УНИВЕРСАЛЬНЫЙ СКРИПТ БЭКАПА PostgreSQL 1C"
    echo "=========================================="
    echo ""
    echo "Выберите режим:"
    echo "  1) Горячий (без остановки 1С) - только физический бэкап"
    echo "  2) Полный (с остановкой 1С) - физический + архивация + дампы"
    echo ""
    read -p "Ваш выбор [1/2]: " MODE_CHOICE
    echo ""
    
    case $MODE_CHOICE in
        2) MODE="full" ;;
        *) MODE="hot" ;;
    esac
else
    # Cron - АВТОМАТИЧЕСКИ ПО ВРЕМЕНИ
    if [ $CURRENT_HOUR -ge 6 ] && [ $CURRENT_HOUR -le 23 ]; then
        MODE="hot"    # 06:00-23:59 - горячий
    else
        MODE="full"   # 00:00-05:59 - полный
    fi
fi

log "=========================================="
log "ЗАПУСК БЭКАПА"
log "Версия PostgreSQL: $(sudo -u postgres psql -V 2>/dev/null | head -1 || echo 'unknown')"
log "pg_probackup: $PG_PROBACKUP"
log "Режим: $MODE"
log "=========================================="

# ========== ФИЗИЧЕСКИЙ БЭКАП (ВСЕГДА) ==========
log "Физический бэкап через pg_probackup..."
sudo -u postgres $PG_PROBACKUP backup \
    -B "$BACKUP_DIR" \
    --instance "$INSTANCE" \
    -b FULL \
    --stream \
    --compress \
    -j 4 \
    -h "$PG_HOST" \
    -p "$PG_PORT" \
    -U "$PG_USER" \
    -d postgres >> "$LOG_FILE" 2>&1

if [ $? -eq 0 ]; then
    log "✓ Физический бэкап успешно завершен"
    
    # Показываем последний бэкап
    LAST_BACKUP=$(sudo -u postgres $PG_PROBACKUP show -B "$BACKUP_DIR" --instance "$INSTANCE" 2>/dev/null | grep OK | tail -1)
    log "Последний бэкап: $LAST_BACKUP"
else
    log "✗ Ошибка физического бэкапа"
fi

# ========== ПОЛНЫЙ РЕЖИМ (ТОЛЬКО НОЧЬЮ ИЛИ ПО ЗАПРОСУ) ==========
if [ "$MODE" = "full" ]; then
    log ""
    log "========== ПОЛНЫЙ РЕЖИМ =========="
    
    # 1. ОСТАНОВКА 1С
    log "Остановка служб 1С..."
    systemctl stop srv1c-* 2>/dev/null
    systemctl stop srv1c* 2>/dev/null
    pkill -f "ragent|rmngr|rphost" 2>/dev/null
    sleep 10
    
    # 2. АРХИВАЦИЯ БЭКАПА В /backups/copy/
    log "Архивация последнего бэкапа в /backups/copy/..."
    LAST_BACKUP_ID=$(ls -t "$BACKUP_DIR/backups/$INSTANCE" 2>/dev/null | head -1)
    if [ -n "$LAST_BACKUP_ID" ] && [ -d "$BACKUP_DIR/backups/$INSTANCE/$LAST_BACKUP_ID" ]; then
        TIMESTAMP=$(date +"%Y-%m-%d_%H-%M")
        mkdir -p "$BACKUPS_DIR/copy"
        
        tar -czf "$BACKUPS_DIR/copy/pg_pro-$TIMESTAMP.tar.gz" \
            -C "$BACKUP_DIR/backups/$INSTANCE" \
            "$LAST_BACKUP_ID" \
            "pg_probackup.conf" 2>/dev/null && \
        md5sum "$BACKUPS_DIR/copy/pg_pro-$TIMESTAMP.tar.gz" > "$BACKUPS_DIR/copy/pg_pro-$TIMESTAMP.tar.gz.md5"
        
        if [ $? -eq 0 ]; then
            log "✓ Архив создан: pg_pro-$TIMESTAMP.tar.gz"
        else
            log "✗ Ошибка архивации"
        fi
    fi
    
    # 3. ЛОГИЧЕСКИЕ ДАМПЫ В /backups/pg_dump/
    log "Создание логических дампов в /backups/pg_dump/..."
    mkdir -p "$BACKUPS_DIR/pg_dump"
    
    DATABASES=$(sudo -u postgres psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -qAt -c \
        "SELECT datname FROM pg_database WHERE datname NOT IN ('postgres','template0','template1')" postgres 2>/dev/null)
    
    for DB in $DATABASES; do
        log "  Дамп базы: $DB"
        sudo -u postgres pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -Fc "$DB" \
            > "$BACKUPS_DIR/pg_dump/${DB}_$TIMESTAMP.dump" 2>/dev/null
        
        if [ $? -eq 0 ]; then
            md5sum "$BACKUPS_DIR/pg_dump/${DB}_$TIMESTAMP.dump" > "$BACKUPS_DIR/pg_dump/${DB}_$TIMESTAMP.dump.md5"
            log "    ✓ Успешно"
        else
            log "    ✗ Ошибка"
            rm -f "$BACKUPS_DIR/pg_dump/${DB}_$TIMESTAMP.dump" 2>/dev/null
        fi
    done
    
    # 4. VACUUM
    log "Выполнение VACUUM..."
    sudo -u postgres vacuumdb -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -afz 2>&1 | head -20 >> "$LOG_FILE"
    log "✓ VACUUM завершен"
    
    # 5. ЗАПУСК 1С
    log "Запуск служб 1С..."
    systemctl start srv1c-* 2>/dev/null
    systemctl start srv1c* 2>/dev/null
    sleep 5
    
    log "========== ПОЛНЫЙ РЕЖИМ ЗАВЕРШЕН =========="
fi

# ========== ОЧИСТКА СТАРЫХ ФАЙЛОВ ==========
log ""
log "Очистка файлов старше $RETENTION_DAYS дней..."

# Очистка pg_probackup
sudo -u postgres $PG_PROBACKUP delete \
    -B "$BACKUP_DIR" \
    --instance "$INSTANCE" \
    --delete-wal \
    --retention-redundancy=15 \
    --retention-window=$RETENTION_DAYS \
    -h "$PG_HOST" \
    -p "$PG_PORT" \
    -U "$PG_USER" \
    -d postgres >> "$LOG_FILE" 2>&1

# Очистка /backups/copy/
find "$BACKUPS_DIR/copy" -name "*.tar.gz" -type f -mtime +$RETENTION_DAYS -delete 2>/dev/null
find "$BACKUPS_DIR/copy" -name "*.md5" -type f -mtime +$RETENTION_DAYS -delete 2>/dev/null
find "$BACKUPS_DIR/pg_dump" -name "*.dump" -type f -mtime +$RETENTION_DAYS -delete 2>/dev/null
find "$BACKUPS_DIR/pg_dump" -name "*.md5" -type f -mtime +$RETENTION_DAYS -delete 2>/dev/null

log "✓ Очистка завершена"

# ========== ИТОГ ==========
log ""
log "=========================================="
log "ИТОГ БЭКАПА:"
log "- Физический бэкап: $BACKUP_DIR/backups/$INSTANCE/"
log "- Архивы: $BACKUPS_DIR/copy/"
log "- Дампы: $BACKUPS_DIR/pg_dump/"
log "- Лог: $LOG_FILE"
log "=========================================="

# Показываем последние 5 бэкапов
log ""
log "Последние бэкапы в $BACKUP_DIR:"
sudo -u postgres $PG_PROBACKUP show -B "$BACKUP_DIR" --instance "$INSTANCE" 2>/dev/null | grep -E "OK|ERROR" | tail -5 >> "$LOG_FILE"
cat "$LOG_FILE" | grep "OK" | tail -5