#!/bin/bash
# Скрипт бэкапа PostgreSQL с последующим обслуживанием БД

# Проверка пользователя
if [ "$(whoami)" != "postgres" ]; then
    echo "ОШИБКА: Скрипт должен запускаться от пользователя postgres!" >&2
    exit 1
fi

# Пути и настройки
CONFIG_FILE="/var/lib/pgpro/_backup/scripts/pg_backup.conf"
LOCK_FILE="/tmp/pg_backup.lock"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
PGPASSFILE="$HOME/.pgpass"

# Проверка наличия .pgpass
[ -f "$PGPASSFILE" ] || {
    echo "ОШИБКА: Файл .pgpass не найден!" >&2
    echo "Создайте его командой: echo \"localhost:5432:*:postgres:ваш_пароль\" > ~/.pgpass && chmod 600 ~/.pgpass" >&2
    exit 1
}

# Функции
error_exit() {
    local msg="$1"
    echo "ОШИБКА: $msg" >&2
    [ -f "$LOCK_FILE" ] && rm -f "$LOCK_FILE"
    exit 1
}

load_config() {
    [ -f "$CONFIG_FILE" ] || error_exit "Конфигурационный файл $CONFIG_FILE не найден"
    source "$CONFIG_FILE" || error_exit "Ошибка загрузки конфигурации"
    
    # Проверка обязательных параметров
    local required_vars=(
        BACKUP_DIR LOG_DIR PG_HOST PG_USER 
        DB_LIST_FILE LOG_LEVEL BACKUP_RETENTION
    )
    for var in "${required_vars[@]}"; do
        [ -z "${!var}" ] && error_exit "Не указан обязательный параметр: $var"
    done
    mkdir -p "$BACKUP_DIR" "$LOG_DIR" || error_exit "Не удалось создать директории"
}

log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [${level^^}] $message" >> "${LOG_DIR}/backup.log"
    [ "$level" == "ERROR" ] && echo "[$timestamp] [${level^^}] $message" >&2
}

check_pg_connection() {
    export PGPASSFILE
    if ! psql -h "$PG_HOST" -U "$PG_USER" -lqt >/dev/null 2>&1; then
        log "ERROR" "Не удалось подключиться к PostgreSQL"
        error_exit "Проверьте доступность PostgreSQL и параметры подключения"
    fi
}

check_db_exists() {
    local db="$1"
    export PGPASSFILE
    if ! psql -h "$PG_HOST" -U "$PG_USER" -lqt | cut -d \| -f 1 | tr -d ' ' | grep -qw "$db"; then
        log "WARNING" "База данных $db не найдена"
        return 1
    fi
    return 0
}

create_backup() {
    local db="$1"
    local backup_file="${BACKUP_DIR}/${TIMESTAMP}-${db}.dump"
    
    log "INFO" "Начало бэкапа БД: $db"
    export PGPASSFILE
    
    # Выполняем бэкап и сохраняем результат
    if pg_dump -h "$PG_HOST" -U "$PG_USER" -Fc "$db" -f "$backup_file" 2>> "${LOG_DIR}/backup.log"; then
        # Получаем размер файла отдельной командой
        local backup_size=$(du -h "$backup_file" | cut -f1)
        log "INFO" "Успешный бэкап БД: $db (размер: $backup_size)"
        return 0
    else
        log "ERROR" "Ошибка при создании бэкапа БД: $db"
        [ -f "$backup_file" ] && rm -f "$backup_file"
        return 1
    fi
}

perform_maintenance() {
    local db="$1"
    export PGPASSFILE
    
    log "INFO" "Начало обслуживания БД: $db"
    
    # VACUUM ANALYZE
    if ! vacuumdb -h "$PG_HOST" -U "$PG_USER" --analyze "$db" >> "${LOG_DIR}/backup.log" 2>&1; then
        log "ERROR" "Ошибка при выполнении VACUUM ANALYZE для БД: $db"
        return 1
    fi
    
    # Полное обслуживание по воскресеньям
    if [ "$(date +%u)" -eq 7 ]; then
        log "INFO" "Полное обслуживание (воскресенье) БД: $db"
        
        # VACUUM FULL
        if ! vacuumdb -h "$PG_HOST" -U "$PG_USER" --full "$db" >> "${LOG_DIR}/backup.log" 2>&1; then
            log "ERROR" "Ошибка при выполнении VACUUM FULL для БД: $db"
            return 1
        fi
        
        # REINDEX
        if ! reindexdb -h "$PG_HOST" -U "$PG_USER" "$db" >> "${LOG_DIR}/backup.log" 2>&1; then
            log "ERROR" "Ошибка при выполнении REINDEX для БД: $db"
            return 1
        fi
    fi
    
    log "INFO" "Обслуживание БД завершено: $db"
    return 0
}

cleanup_old_backups() {
    log "INFO" "Очистка старых бэкапов (старше $BACKUP_RETENTION дней)"
    find "$BACKUP_DIR" -type f -name "*.dump" -mtime "+$BACKUP_RETENTION" -delete 2>/dev/null || {
        log "WARNING" "Ошибка при удалении старых бэкапов"
    }
}

### ОСНОВНОЙ БЛОК ###
load_config
check_pg_connection

# Блокировка
if [ -e "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE")
    if kill -0 "$pid" 2>/dev/null; then
        error_exit "Скрипт уже выполняется (PID: $pid)"
    else
        rm -f "$LOCK_FILE"
    fi
fi
echo $$ > "$LOCK_FILE"
trap '[ -f "$LOCK_FILE" ] && rm -f "$LOCK_FILE"' EXIT

log "INFO" "=== СТАРТ ПРОЦЕДУРЫ БЭКАПА ==="

while read -r db_line; do
    [[ "$db_line" =~ ^#|^$ ]] && continue
    db_name=$(echo "$db_line" | awk '{print $1}')
    
    if check_db_exists "$db_name"; then
        # Сначала создаем бэкап
        if create_backup "$db_name"; then
            # ТОЛЬКО если бэкап успешен - выполняем обслуживание
            log "INFO" "Бэкап успешен, начинаем обслуживание БД: $db_name"
            if ! perform_maintenance "$db_name"; then
                log "ERROR" "Ошибка обслуживания БД: $db_name (бэкап сохранен)"
            fi
        else
            log "ERROR" "Пропускаем обслуживание - бэкап БД $db_name не удался"
        fi
    fi
done < "$DB_LIST_FILE"

cleanup_old_backups
log "INFO" "=== ПРОЦЕДУРА ЗАВЕРШЕНА ==="
exit 0
