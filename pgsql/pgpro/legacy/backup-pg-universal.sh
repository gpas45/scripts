#!/bin/bash
# =================================================================
# backup-pg-universal.sh - Универсальный скрипт бэкапа PostgreSQL 1C
# Автоматически определяет режим по времени суток
# =================================================================

set -e
exec 2>&1

# =================================================================
# КОНФИГУРАЦИЯ
# =================================================================

# Пароль PostgreSQL (если нужен)
readonly PG_PASSWORD="pass"

# Временные диапазоны
readonly DAY_START=6      # 06:00 - начало дня
readonly DAY_END=23       # 23:59 - конец дня

# Пути и имена
readonly BACKUP_ROOT="/backup"
readonly ARCHIVE_ROOT="/backups"
readonly PG_DATA="/var/lib/pgpro/1c-17/data"
readonly INSTANCE="data"

# Каталоги
readonly COPY_DIR="$ARCHIVE_ROOT/copy"
readonly DUMP_DIR="$ARCHIVE_ROOT/pg_dump"
readonly LOG_DIR="$BACKUP_ROOT/log"

# Хранение бэкапов (дней)
readonly RETENTION_DAYS=20
readonly RETENTION_COPIES=15

# Уведомления
readonly MAIL_ENABLED=false
readonly MAIL_TO="root"

# =================================================================
# ИНИЦИАЛИЗАЦИЯ И ОПРЕДЕЛЕНИЕ РЕЖИМА
# =================================================================

# Автоопределение версии pg_probackup
detect_pg_probackup() {
    # Ищем доступные версии
    for version in 19 18 17 16 15 14 13 12; do
        if command -v "pg_probackup-$version" &>/dev/null; then
            echo "pg_probackup-$version"
            return 0
        fi
    done
    
    # Пробуем просто pg_probackup
    if command -v "pg_probackup" &>/dev/null; then
        echo "pg_probackup"
        return 0
    fi
    
    echo "ОШИБКА: pg_probackup не найден!" >&2
    exit 1
}

# Автоопределение пути к бинарникам PostgreSQL
detect_pg_bin() {
    # Проверяем стандартные пути
    local paths=(
        "/opt/pgpro/1c-17/bin"
        "/opt/pgpro/1c-16/bin"
        "/opt/pgpro/1c-15/bin"
        "/usr/pgsql-17/bin"
        "/usr/pgsql-16/bin"
        "/usr/pgsql-15/bin"
        "/usr/bin"
        "/usr/local/bin"
    )
    
    for path in "${paths[@]}"; do
        if [ -x "$path/psql" ]; then
            echo "$path"
            return 0
        fi
    done
    
    echo "ОШИБКА: PostgreSQL binaries не найдены!" >&2
    exit 1
}

# Определение режима работы
determine_mode() {
    local current_hour=$(date +%H)
    
    # Если указан параметр --hot или --full
    case "$1" in
        "--hot")
            echo "hot"
            return
            ;;
        "--full")
            echo "full"
            return
            ;;
        "--help")
            show_help
            exit 0
            ;;
    esac
    
    # Если запущен из cron (нет TTY) или явно указан CRON_MODE
    if [[ ! -t 0 ]] || [[ -n "$CRON_MODE" ]]; then
        # Автоматический режим - определяем по времени
        if (( current_hour >= DAY_START && current_hour <= DAY_END )); then
            echo "hot"    # День: 06:00-23:59 - ГОРЯЧИЙ
        else
            echo "full"   # Ночь: 00:00-05:59 - ПОЛНЫЙ
        fi
    else
        # Ручной запуск - спрашиваем пользователя
        echo "================================================" >&2
        echo "Универсальный скрипт бэкапа PostgreSQL 1C" >&2
        echo "================================================" >&2
        echo "" >&2
        
        read -p "Выберите режим работы:
  1) Горячий бэкап (без остановки 1С, только физический бэкап)
  2) Полный бэкап (с остановкой 1С, архивацией и логическими дампами)
  
Ваш выбор [1/2]: " choice
        
        case "${choice:-2}" in
            1) echo "hot" ;;
            *) echo "full" ;;
        esac
    fi
}

# Показать справку
show_help() {
    cat << EOF
Использование: $0 [ПАРАМЕТР]

Параметры:
  --hot     Принудительно горячий режим (без остановки 1С)
  --full    Принудительно полный режим (с остановкой 1С)
  --help    Показать эту справку

Без параметров:
  - Ручной запуск: спрашивает режим
  - Cron запуск: автоматически по времени суток
    День (06:00-23:59): горячий режим
    Ночь (00:00-05:59): полный режим

Примеры:
  $0              # Ручной запуск, спрашивает режим
  $0 --hot        # Принудительно горячий режим
  $0 --full       # Принудительно полный режим
  
  # В cron (каждый час)
  0 * * * * $0
EOF
}

# Инициализация
init() {
    # Определяем компоненты
    readonly PG_PROBACKUP=$(detect_pg_probackup)
    readonly PG_BIN=$(detect_pg_bin)
    
    # Создаем каталоги
    mkdir -p "$LOG_DIR" "$COPY_DIR" "$DUMP_DIR" "$BACKUP_ROOT/backups/$INSTANCE"
    chown -R postgres:postgres "$BACKUP_ROOT" "$ARCHIVE_ROOT" 2>/dev/null || true
    
    # Определяем режим
    readonly MODE=$(determine_mode "$1")
    
    # Главный лог
    readonly TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    readonly MAIN_LOG="$LOG_DIR/backup_${TIMESTAMP}_${MODE}.log"
    
    # Настраиваем аутентификацию
    setup_auth
    
    log_header
}

# Настройка аутентификации
setup_auth() {
    # Экспортируем пароль если указан
    [ -n "$PG_PASSWORD" ] && export PGPASSWORD="$PG_PASSWORD"
    
    # Создаем .pgpass если нужно
    local pgpass_file="/var/lib/pgpro/.pgpass"
    if [ ! -f "$pgpass_file" ] && [ -n "$PG_PASSWORD" ]; then
        sudo -u postgres bash -c "echo 'localhost:5432:*:postgres:$PG_PASSWORD' > '$pgpass_file'"
        sudo -u postgres bash -c "echo '127.0.0.1:5432:*:postgres:$PG_PASSWORD' >> '$pgpass_file'"
        sudo chmod 600 "$pgpass_file"
    fi
}

# =================================================================
# ЛОГИРОВАНИЕ
# =================================================================

log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$level] $message" | tee -a "$MAIN_LOG"
}

log_header() {
    cat << EOF | tee -a "$MAIN_LOG"
========================================================
БЭКАП POSTGRESQL 1C - $(date)
Режим: $MODE ($([ "$MODE" = "hot" ] && echo "Горячий" || echo "Полный"))
pg_probackup: $PG_PROBACKUP
PostgreSQL: $PG_BIN
========================================================
EOF
}

# =================================================================
# УПРАВЛЕНИЕ СЛУЖБАМИ 1С
# =================================================================

stop_1c_services() {
    log "INFO" "Остановка служб 1С..."
    
    # Ищем все службы 1С
    local services=$(systemctl list-unit-files --type=service 2>/dev/null | \
        grep -E "(srv1c|1c.*service)" | awk '{print $1}' || true)
    
    if [ -z "$services" ]; then
        log "WARNING" "Службы 1С не найдены в systemd"
        # Пробуем убить процессы напрямую
        pkill -f "ragent\|rmngr\|rphost" 2>/dev/null && \
            log "INFO" "Процессы 1С остановлены" || \
            log "INFO" "Процессы 1С не найдены"
        return 0
    fi
    
    # Останавливаем RAS сначала
    for service in $services; do
        if [[ "$service" == *"ras"* ]] || [[ "$service" == *"RAS"* ]]; then
            log "INFO" "Останавливаем: $service"
            systemctl stop "$service" 2>/dev/null && \
                log "INFO" "  ✓ Остановлена" || \
                log "WARNING" "  ✗ Ошибка остановки"
            sleep 2
        fi
    done
    
    # Останавливаем остальные
    for service in $services; do
        if [[ "$service" != *"ras"* ]] && [[ "$service" != *"RAS"* ]]; then
            log "INFO" "Останавливаем: $service"
            systemctl stop "$service" 2>/dev/null && \
                log "INFO" "  ✓ Остановлена" || \
                log "WARNING" "  ✗ Ошибка остановки"
            sleep 3
        fi
    done
    
    # Дополнительная проверка
    sleep 5
    local running_count=$(ps aux | grep -E "ragent|rmngr|rphost" | grep -v grep | wc -l)
    if [ "$running_count" -eq 0 ]; then
        log "INFO" "Все службы 1С остановлены"
    else
        log "WARNING" "Осталось процессов 1С: $running_count"
    fi
}

start_1c_services() {
    log "INFO" "Запуск служб 1С..."
    
    local services=$(systemctl list-unit-files --type=service 2>/dev/null | \
        grep -E "(srv1c|1c.*service)" | awk '{print $1}' || true)
    
    if [ -z "$services" ]; then
        log "WARNING" "Службы 1С не найдены"
        return 0
    fi
    
    # Запускаем основные службы (кроме RAS)
    for service in $services; do
        if [[ "$service" != *"ras"* ]] && [[ "$service" != *"RAS"* ]]; then
            log "INFO" "Запускаем: $service"
            systemctl start "$service" 2>/dev/null && \
                log "INFO" "  ✓ Запущена" || \
                log "WARNING" "  ✗ Ошибка запуска"
            sleep 5
        fi
    done
    
    # Запускаем RAS службы
    for service in $services; do
        if [[ "$service" == *"ras"* ]] || [[ "$service" == *"RAS"* ]]; then
            log "INFO" "Запускаем: $service"
            systemctl start "$service" 2>/dev/null && \
                log "INFO" "  ✓ Запущена" || \
                log "WARNING" "  ✗ Ошибка запуска"
            sleep 2
        fi
    done
    
    log "INFO" "Службы 1С запущены"
}

# =================================================================
# ФИЗИЧЕСКИЙ БЭКАП (PG_PROBACKUP)
# =================================================================

execute_backup() {
    local backup_log="$LOG_DIR/pg_probackup_${TIMESTAMP}.log"
    local start_time=$(date +%s)
    
    log "INFO" "Выполнение pg_probackup ($MODE режим)..."
    
    # Базовые параметры
    local cmd="sudo -u postgres $PG_PROBACKUP backup \
        -B '$BACKUP_ROOT' \
        --instance '$INSTANCE' \
        -b FULL \
        --stream \
        --compress \
        -j 4"
    
    # Добавляем delete-wal только в полном режиме
    if [ "$MODE" = "full" ]; then
        cmd="$cmd --delete-wal"
    fi
    
    log "DEBUG" "Команда: $cmd"
    
    # Выполняем бэкап
    if eval "$cmd" > "$backup_log" 2>&1; then
        # Проверяем результат
        if grep -q "completed" "$backup_log"; then
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            
            # Копируем лог в основной
            cat "$backup_log" >> "$MAIN_LOG"
            
            log "SUCCESS" "Бэкап успешно завершен за ${duration}с"
            
            # Добавляем информацию о размере
            local backup_size=$(du -sh "$BACKUP_ROOT/backups/$INSTANCE" 2>/dev/null | cut -f1)
            log "INFO" "Размер бэкапов: $backup_size"
            
            return 0
        else
            log "ERROR" "Бэкап выполнен, но нет статуса completed"
            cat "$backup_log" >> "$MAIN_LOG"
            return 1
        fi
    else
        log "ERROR" "Ошибка выполнения pg_probackup"
        cat "$backup_log" >> "$MAIN_LOG"
        return 1
    fi
}

# =================================================================
# АРХИВАЦИЯ БЭКАПА (ТОЛЬКО В ПОЛНОМ РЕЖИМЕ)
# =================================================================

archive_backup() {
    [ "$MODE" != "full" ] && return 0
    
    log "INFO" "Архивация бэкапа в .tar.gz..."
    
    # Ищем последний бэкап
    local last_backup=$(sudo -u postgres ls "$BACKUP_ROOT/backups/$INSTANCE" -t 2>/dev/null | head -1)
    
    if [ -z "$last_backup" ]; then
        log "ERROR" "Не найден бэкап для архивации"
        return 1
    fi
    
    # Проверяем что бэкап завершен
    if ! sudo -u postgres grep -q "$last_backup completed" "$LOG_DIR/pg_probackup.log" 2>/dev/null; then
        log "ERROR" "Бэкап $last_backup не завершен"
        return 1
    fi
    
    local archive_file="$COPY_DIR/pg_pro-${TIMESTAMP}.tar.gz"
    
    log "INFO" "Создание архива: $archive_file"
    log "INFO" "Исходник: $last_backup"
    
    # Архивируем
    if sudo -u postgres tar -czf "$archive_file" \
        -C "$BACKUP_ROOT/backups/$INSTANCE" \
        "$last_backup" \
        "pg_probackup.conf" > /dev/null 2>&1; then
        
        # MD5 сумма
        sudo -u postgres md5sum "$archive_file" > "${archive_file}.md5"
        
        # Логируем
        local size=$(du -h "$archive_file" | cut -f1)
        echo "$(date '+%Y-%m-%d %H:%M:%S') создан $archive_file ($size)" >> "$COPY_DIR/copy.log"
        
        log "SUCCESS" "Архив создан: $archive_file ($size)"
        return 0
    else
        log "ERROR" "Ошибка создания архива"
        return 1
    fi
}

# =================================================================
# ЛОГИЧЕСКИЕ ДАМПЫ (ТОЛЬКО В ПОЛНОМ РЕЖИМЕ)
# =================================================================

logical_dumps() {
    [ "$MODE" != "full" ] && return 0
    
    log "INFO" "Создание логических дампов (pg_dump)..."
    
    # Получаем список баз (исключая системные)
    local databases=$(sudo -u postgres "$PG_BIN/psql" -qAt -c "
        SELECT datname 
        FROM pg_database 
        WHERE datname NOT IN ('postgres', 'template0', 'template1')
        ORDER BY datname;
    " 2>/dev/null)
    
    if [ -z "$databases" ]; then
        log "WARNING" "Пользовательские БД не найдены"
        return 1
    fi
    
    log "INFO" "Найдено баз: $(echo "$databases" | wc -l)"
    
    local success=0
    local total=0
    
    for db in $databases; do
        total=$((total + 1))
        
        local dump_file="$DUMP_DIR/${db}_${TIMESTAMP}.dump"
        local start_time=$(date +%s)
        
        log "INFO" "Дамп базы: $db"
        
        if sudo -u postgres "$PG_BIN/pg_dump" -Fc "$db" > "$dump_file" 2>"$DUMP_DIR/${db}_error.log"; then
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            local size=$(du -h "$dump_file" | cut -f1)
            
            # MD5 сумма
            sudo -u postgres md5sum "$dump_file" > "${dump_file}.md5"
            
            log "SUCCESS" "  ✓ Дамп создан за ${duration}с ($size)"
            success=$((success + 1))
        else
            log "ERROR" "  ✗ Ошибка дампа"
            rm -f "$dump_file" 2>/dev/null
        fi
    done
    
    # Итоговый лог
    echo "$(date '+%Y-%m-%d %H:%M:%S') Дампы: $success/$total успешно" >> "$DUMP_DIR/backup.log"
    
    if [ $success -gt 0 ]; then
        log "SUCCESS" "Создано $success/$total дампов"
        return 0
    else
        log "ERROR" "Не создано ни одного дампа"
        return 1
    fi
}

# =================================================================
# VACUUM (ТОЛЬКО В ПОЛНОМ РЕЖИМЕ)
# =================================================================

execute_vacuum() {
    [ "$MODE" != "full" ] && return 0
    
    log "INFO" "Выполнение VACUUM..."
    local vacuum_log="$LOG_DIR/vacuum_${TIMESTAMP}.log"
    local start_time=$(date +%s)
    
    if sudo -u postgres "$PG_BIN/vacuumdb" -afz > "$vacuum_log" 2>&1; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        log "SUCCESS" "VACUUM успешно завершен за ${duration}с"
        
        # Добавляем детальный лог
        if [ "$MAIL_ENABLED" = true ]; then
            cat "$vacuum_log" >> "$MAIN_LOG"
        fi
    else
        log "ERROR" "Ошибка VACUUM"
        cat "$vacuum_log" >> "$MAIN_LOG"
    fi
}

# =================================================================
# ОЧИСТКА СТАРЫХ ФАЙЛОВ
# =================================================================

cleanup_old() {
    log "INFO" "Очистка старых файлов (>${RETENTION_DAYS} дней)..."
    
    # Архивированные бэкапы
    find "$COPY_DIR" -name "*.tar.gz" -type f -mtime +$RETENTION_DAYS -delete 2>/dev/null
    find "$COPY_DIR" -name "*.md5" -type f -mtime +$RETENTION_DAYS -delete 2>/dev/null
    
    # Логические дампы
    find "$DUMP_DIR" -name "*.dump" -type f -mtime +$RETENTION_DAYS -delete 2>/dev/null
    find "$DUMP_DIR" -name "*.md5" -type f -mtime +$RETENTION_DAYS -delete 2>/dev/null
    
    # Старые логи
    find "$LOG_DIR" -name "*.log" -type f -mtime +90 -delete 2>/dev/null
    
    # Очистка через pg_probackup (для физических бэкапов)
    sudo -u postgres $PG_PROBACKUP delete \
        -B "$BACKUP_ROOT" \
        --instance "$INSTANCE" \
        --retention-redundancy=$RETENTION_COPIES \
        --retention-window=$RETENTION_DAYS \
        > /dev/null 2>&1
    
    log "INFO" "Очистка завершена (сохранено последних $RETENTION_COPIES копий)"
}

# =================================================================
# ПРОВЕРКА ЦЕЛОСТНОСТИ
# =================================================================

validate_backups() {
    log "INFO" "Проверка целостности бэкапов..."
    
    if sudo -u postgres $PG_PROBACKUP validate \
        -B "$BACKUP_ROOT" \
        --instance "$INSTANCE" \
        > "$LOG_DIR/validate_${TIMESTAMP}.log" 2>&1; then
        log "SUCCESS" "Все бэкапы целостны"
    else
        log "ERROR" "Найдены повреждённые бэкапы"
        cat "$LOG_DIR/validate_${TIMESTAMP}.log" >> "$MAIN_LOG"
    fi
}

# =================================================================
# ОТПРАВКА УВЕДОМЛЕНИЙ
# =================================================================

send_notification() {
    [ "$MAIL_ENABLED" != "true" ] && return 0
    
    local subject="Бэкап PostgreSQL ($MODE режим) - $(date '+%Y-%m-%d %H:%M')"
    
    if command -v mutt >/dev/null 2>&1; then
        cat "$MAIN_LOG" | mutt -s "$subject" "$MAIL_TO"
        log "INFO" "Уведомление отправлено на $MAIL_TO"
    else
        log "WARNING" "mutt не установлен, уведомления недоступны"
    fi
}

# =================================================================
# ГЛАВНАЯ ФУНКЦИЯ
# =================================================================

main() {
    # Инициализация
    init "$1"
    
    log "INFO" "Начало выполнения в режиме: $MODE"
    
    # ПОЛНЫЙ РЕЖИМ: останавливаем 1С
    if [ "$MODE" = "full" ]; then
        stop_1c_services
    fi
    
    # Физический бэкап (всегда)
    if execute_backup; then
        # Проверка целостности
        validate_backups
        
        # ПОЛНЫЙ РЕЖИМ: дополнительные операции
        if [ "$MODE" = "full" ]; then
            # Архивация
            archive_backup
            
            # Логические дампы
            logical_dumps
            
            # VACUUM
            execute_vacuum
            
            # Запускаем 1С обратно
            start_1c_services
        fi
        
        # Очистка старых файлов (всегда)
        cleanup_old
        
        log "SUCCESS" "Бэкап успешно завершен в режиме: $MODE"
    else
        log "ERROR" "Бэкап не удался!"
        
        # Если в полном режиме - пытаемся запустить 1С обратно
        if [ "$MODE" = "full" ]; then
            log "INFO" "Пытаемся запустить 1С после ошибки..."
            start_1c_services
        fi
    fi
    
    # Итоговое время выполнения
    local total_duration=$(( $(date +%s) - ${START_TIME:-$(date +%s)} ))
    log "INFO" "Общее время выполнения: ${total_duration}с"
    
    # Уведомления
    send_notification
    
    # Итоговый разделитель
    echo "========================================================" | tee -a "$MAIN_LOG"
}

# =================================================================
# ЗАПУСК
# =================================================================

# Засекаем время
readonly START_TIME=$(date +%s)

# Проверка прав
if [ "$(id -u)" -ne 0 ]; then
    echo "ОШИБКА: Запускайте от root" >&2
    exit 1
fi

# Ловим прерывания
trap 'echo "Прервано пользователем"; exit 1' INT TERM

# Запускаем
main "$@"