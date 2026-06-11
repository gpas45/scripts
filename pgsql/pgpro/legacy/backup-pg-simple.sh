#!/bin/bash
# backup-pg-working.sh - РАБОЧИЙ скрипт бэкапа
# Проверено - работает!

# Проверка root
if [ "$(id -u)" -ne 0 ]; then
    echo "Запускай: sudo $0"
    exit 1
fi

# Безопасный режим
set -e

# ========== КОНФИГ ==========
PG_PASSWORD='pass'          # Пароль postgres
PG_HOST='127.0.0.1'         # Адрес сервера
PG_PORT='5432'              # Порт
PG_USER='postgres'          # Пользователь

ARCHIV_DIR='/backups'
BACKUP_DIR='/backup'

# ========== ФУНКЦИИ ==========
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

stop_1c() {
    log "Останавливаю службы 1С..."
    
    # Сначала пытаемся через systemd
    for service in $(systemctl list-units --type=service --no-legend 2>/dev/null | grep -E "srv1c|1c" | awk '{print $1}'); do
        systemctl stop "$service" 2>/dev/null && log "  Остановлена: $service"
    done
    
    sleep 3
    
    # Добиваем процессы если остались
    pkill -f "ragent" 2>/dev/null || true
    pkill -f "rmngr" 2>/dev/null || true
    pkill -f "rphost" 2>/dev/null || true
    sleep 2
    
    log "Службы 1С остановлены"
}

start_1c() {
    log "Запускаю службы 1С..."
    
    # Запускаем все найденные службы 1С
    for service in $(systemctl list-units --type=service --no-legend --state=inactive 2>/dev/null | grep -E "srv1c|1c" | awk '{print $1}'); do
        systemctl start "$service" 2>/dev/null && log "  Запущена: $service"
        sleep 1
    done
    
    log "Службы 1С запущены"
}

# ========== ОПРЕДЕЛЕНИЕ РЕЖИМА ==========
current_hour=$(date +%H)

# Если запущен из терминала - спрашиваем
if [ -t 0 ]; then
    echo ""
    echo "=== БЭКАП POSTGRESQL ==="
    echo "Выбери режим:"
    echo "  1) Быстрый (без остановки 1С, только физический бэкап)"
    echo "  2) Полный (с остановкой 1С + архивация + дампы)"
    echo ""
    read -p "Твой выбор (1/2): " choice
    
    if [ "$choice" = "2" ]; then
        MODE="full"
    else
        MODE="fast"
    fi
else
    # Авторежим для cron
    if [ $current_hour -ge 6 ] && [ $current_hour -le 23 ]; then
        MODE="fast"      # День - быстрый
    else
        MODE="full"      # Ночь - полный
    fi
fi

log "Начинаю бэкап в режиме: $MODE"

# ========== ПРОВЕРКА ПОДКЛЮЧЕНИЯ К POSTGRESQL ==========
log "Проверяю подключение к PostgreSQL..."
if ! sudo -u postgres PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -c "SELECT 1;" postgres >/dev/null 2>&1; then
    log "ОШИБКА: Не могу подключиться к PostgreSQL!"
    exit 1
fi
log "Подключение к PostgreSQL - OK"

# ========== ВЫПОЛНЕНИЕ БЭКАПА ==========
if [ "$MODE" = "full" ]; then
    # ========== ПОЛНЫЙ РЕЖИМ ==========
    log "=== ПОЛНЫЙ РЕЖИМ ==="
    
    # 1. Останавливаем 1С
    stop_1c
    sleep 5
    
    # 2. Физический бэкап
    log "Делаю физический бэкап..."
    sudo -u postgres PGPASSWORD="$PG_PASSWORD" pg_probackup-17 backup \
        -B "$BACKUP_DIR" \
        --instance data \
        -b FULL \
        --stream \
        --compress \
        -j 4 \
        -h "$PG_HOST" \
        -p "$PG_PORT" \
        -U "$PG_USER" \
        -d postgres
    
    # 3. Архивируем
    log "Архивирую бэкап..."
    LAST_BACKUP=$(ls -t "$BACKUP_DIR/backups/data" 2>/dev/null | head -1)
    if [ -n "$LAST_BACKUP" ]; then
        TIMESTAMP=$(date +"%Y-%m-%d_%H-%M")
        mkdir -p "$ARCHIV_DIR/copy"
        
        if tar -czf "$ARCHIV_DIR/copy/pg_pro-$TIMESTAMP.tar.gz" \
            -C "$BACKUP_DIR/backups/data" \
            "$LAST_BACKUP" \
            "pg_probackup.conf" 2>/dev/null; then
            
            md5sum "$ARCHIV_DIR/copy/pg_pro-$TIMESTAMP.tar.gz" > "$ARCHIV_DIR/copy/pg_pro-$TIMESTAMP.tar.gz.md5"
            log "Архив создан: pg_pro-$TIMESTAMP.tar.gz"
        else
            log "Ошибка архивации!"
        fi
    fi
    
    # 4. Логические дампы
    log "Создаю логические дампы..."
    mkdir -p "$ARCHIV_DIR/pg_dump"
    
    DBS=$(sudo -u postgres PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -qAt -c \
        "SELECT datname FROM pg_database WHERE datname NOT IN ('postgres','template0','template1')" postgres)
    
    for DB in $DBS; do
        log "  Дамп базы: $DB"
        sudo -u postgres PGPASSWORD="$PG_PASSWORD" pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -Fc "$DB" \
            > "$ARCHIV_DIR/pg_dump/${DB}_$TIMESTAMP.dump" 2>/dev/null
        
        if [ $? -eq 0 ]; then
            md5sum "$ARCHIV_DIR/pg_dump/${DB}_$TIMESTAMP.dump" > "$ARCHIV_DIR/pg_dump/${DB}_$TIMESTAMP.dump.md5"
            log "    ✓ Успешно"
        else
            log "    ✗ Ошибка"
            rm -f "$ARCHIV_DIR/pg_dump/${DB}_$TIMESTAMP.dump"
        fi
    done
    
    # 5. VACUUM
    log "Выполняю VACUUM..."
    sudo -u postgres PGPASSWORD="$PG_PASSWORD" vacuumdb -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -afz 2>/dev/null
    
    # 6. Запускаем 1С
    start_1c
    
else
    # ========== БЫСТРЫЙ РЕЖИМ ==========
    log "=== БЫСТРЫЙ РЕЖИМ ==="
    
    # Только физический бэкап
    log "Делаю быстрый бэкап (без остановки 1С)..."
    sudo -u postgres PGPASSWORD="$PG_PASSWORD" pg_probackup-17 backup \
        -B "$BACKUP_DIR" \
        --instance data \
        -b FULL \
        --stream \
        --compress \
        -j 4 \
        -h "$PG_HOST" \
        -p "$PG_PORT" \
        -U "$PG_USER" \
        -d postgres
fi

# ========== ОЧИСТКА СТАРЫХ ФАЙЛОВ ==========
log "Очищаю старые файлы..."
# Храним 20 дней
find "$ARCHIV_DIR/copy" -name "*.tar.gz" -mtime +20 -delete 2>/dev/null || true
find "$ARCHIV_DIR/copy" -name "*.md5" -mtime +20 -delete 2>/dev/null || true
find "$ARCHIV_DIR/pg_dump" -name "*.dump" -mtime +20 -delete 2>/dev/null || true
find "$ARCHIV_DIR/pg_dump" -name "*.md5" -mtime +20 -delete 2>/dev/null || true

# Очистка через pg_probackup
sudo -u postgres PGPASSWORD="$PG_PASSWORD" pg_probackup-17 delete \
    -B "$BACKUP_DIR" \
    --instance data \
    --delete-wal \
    --retention-redundancy=15 \
    --retention-window=20 \
    -h "$PG_HOST" \
    -p "$PG_PORT" \
    -U "$PG_USER" \
    -d postgres 2>/dev/null

# ========== ИТОГ ==========
log "Бэкап успешно завершен в режиме: $MODE"
log "Лог бэкапа: sudo -u postgres pg_probackup-17 show -B $BACKUP_DIR"
echo ""