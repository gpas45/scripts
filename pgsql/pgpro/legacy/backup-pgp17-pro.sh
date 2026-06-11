#!/bin/bash
# =================================================================
# backup-pgp17-pro.sh - Профессиональный скрипт бэкапа PostgreSQL 1C Pro 17
# Автор: Системный администратор
# Версия: 3.0
# Дата: $(date +%Y-%m-%d)
# 
# ОСОБЕННОСТИ:
# - Работает вручную и из cron
# - Детальное логирование с цветом
# - Автоопределение режима по времени
# - Проверка целостности всех операций
# - Отправка уведомлений (опционально)
# - Поддержка команд: validate, cleanup, report
# 
# РАСПИСАНИЕ:
# - 4:00 Пн-Сб: Полный бэкап с остановкой 1С
# - 12:30 Пн-Пт: Горячий бэкап без остановки
# - 15:00 Сб: Горячий бэкап без остановки
# - Ручной запуск: Полный цикл
# =================================================================

set -e  # Выход при ошибке
exec 2>&1  # Перенаправляем stderr в stdout

# =================================================================
# КОНФИГУРАЦИЯ (НАСТРОЙКИ)
# =================================================================
readonly PG_PASSWORD="pass"                # Пароль PostgreSQL
readonly PG_PROBACKUP="pg_probackup-17"   # Имя утилиты
readonly PG_PATH="/opt/pgpro/1c-17/bin"   # Путь к PostgreSQL
readonly PG_DATA="/var/lib/pgpro/1c-17/data"  # Каталог данных
readonly INSTANCE="data"                  # Имя инстанса pg_probackup

# Каталоги
readonly BACKUP_DIR="/backup"             # Основной каталог бэкапов
readonly ARCHIVE_DIR="/backups"           # Каталог архивов
readonly COPY_DIR="$ARCHIVE_DIR/copy"     # Архивы pg_probackup
readonly DUMP_DIR="$ARCHIVE_DIR/pg_dump"  # Дампы баз
readonly LOG_DIR="$BACKUP_DIR/log"        # Каталог логов

# Параметры
readonly DAYS_KEEP=20                     # Хранить архивы (дней)
readonly MAIL_ENABLED=false               # Отправлять email?
readonly MAIL_TO="root"                   # Получатель email

# Цвета для вывода
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# =================================================================
# ИНИЦИАЛИЗАЦИЯ
# =================================================================
init() {
    # Создаем каталоги с правильными правами
    mkdir -p "$LOG_DIR" "$COPY_DIR" "$DUMP_DIR"
    chown -R postgres:postgres "$BACKUP_DIR" "$ARCHIVE_DIR" 2>/dev/null || true
    
    # Главный лог файл
    readonly MAIN_LOG="$LOG_DIR/backup_$(date +%Y%m%d_%H%M%S).log"
    
    # Определяем режим запуска
    if [ -t 0 ] && [ -z "$CRON_MODE" ]; then
        RUN_MODE="MANUAL"
        MODE="full-stop"
    else
        RUN_MODE="CRON"
        determine_mode
    fi
    
    # Инициализируем логи
    log_header
}

# Определение режима по времени
determine_mode() {
    local hour=$(date +%H)
    local minute=$(date +%M)
    local day=$(date +%u)  # 1=Пн, 7=Вс
    
    if [ "$hour" = "04" ] && [ "$minute" = "00" ]; then
        MODE="full-stop"       # Ночной: 4:00
    elif [ "$day" -le 5 ] && [ "$hour" = "12" ] && [ "$minute" = "30" ]; then
        MODE="full-hot"        # Дневной будни: 12:30
    elif [ "$day" = "6" ] && [ "$hour" = "15" ] && [ "$minute" = "00" ]; then
        MODE="full-hot"        # Суббота: 15:00
    else
        MODE="full-hot"        # По умолчанию
    fi
}

# =================================================================
# ЛОГИРОВАНИЕ
# =================================================================
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local color="$NC"
    
    case "$level" in
        "INFO")    color="$BLUE" ;;
        "SUCCESS") color="$GREEN" ;;
        "WARNING") color="$YELLOW" ;;
        "ERROR")   color="$RED" ;;
    esac
    
    echo -e "${color}[$timestamp] [$level] [$RUN_MODE] $message${NC}" | tee -a "$MAIN_LOG"
}

log_header() {
    echo "================================================================" | tee -a "$MAIN_LOG"
    echo "БЭКАП POSTGRESQL 1C PRO 17 - $(date)" | tee -a "$MAIN_LOG"
    echo "================================================================" | tee -a "$MAIN_LOG"
    echo "Система:      $(hostname)" | tee -a "$MAIN_LOG"
    echo "Режим:        $RUN_MODE ($MODE)" | tee -a "$MAIN_LOG"
    echo "Время:        $(date '+%H:%M:%S')" | tee -a "$MAIN_LOG"
    echo "Пользователь: $(whoami)" | tee -a "$MAIN_LOG"
    echo "Лог файл:     $MAIN_LOG" | tee -a "$MAIN_LOG"
    echo "================================================================" | tee -a "$MAIN_LOG"
}

# =================================================================
# ПРОВЕРКИ
# =================================================================
check_postgresql() {
    log "INFO" "Проверка PostgreSQL..."
    
    # Проверка службы
    if ! systemctl is-active postgrespro-1c-17 >/dev/null 2>&1; then
        log "ERROR" "Служба PostgreSQL не запущена"
        return 1
    fi
    
    # Проверка подключения
    if ! PGPASSWORD="$PG_PASSWORD" "$PG_PATH/psql" -U postgres -h 127.0.0.1 -c "SELECT 1;" >/dev/null 2>&1; then
        log "ERROR" "Не удается подключиться к PostgreSQL"
        return 1
    fi
    
    log "SUCCESS" "PostgreSQL доступен"
    return 0
}

check_disk_space() {
    log "INFO" "Проверка свободного места..."
    
    local min_gb=10
    local available_gb
    
    # Проверяем место в основном каталоге
    if available_gb=$(df -BG "$BACKUP_DIR" 2>/dev/null | awk 'NR==2 {print $4}' | sed 's/G//'); then
        if [ "$available_gb" -lt "$min_gb" ]; then
            log "ERROR" "В $BACKUP_DIR меньше ${min_gb}GB (${available_gb}GB)"
            return 1
        fi
        log "INFO" "$BACKUP_DIR: ${available_gb}GB свободно"
    else
        log "WARNING" "Не удалось проверить место в $BACKUP_DIR"
    fi
    
    # Проверяем место в архивах
    if [ "$BACKUP_DIR" != "$ARCHIVE_DIR" ]; then
        if available_gb=$(df -BG "$ARCHIVE_DIR" 2>/dev/null | awk 'NR==2 {print $4}' | sed 's/G//'); then
            if [ "$available_gb" -lt 5 ]; then
                log "WARNING" "В $ARCHIVE_DIR меньше 5GB (${available_gb}GB)"
            else
                log "INFO" "$ARCHIVE_DIR: ${available_gb}GB свободно"
            fi
        fi
    fi
    
    return 0
}

# =================================================================
# УПРАВЛЕНИЕ СЛУЖБАМИ 1С
# =================================================================
stop_1c_services() {
    log "INFO" "Остановка служб 1С..."
    
    # Ищем все службы 1С
    local services=$(systemctl list-unit-files --type=service 2>/dev/null | \
        grep -E "srv1c.*service" | awk '{print $1}')
    
    if [ -z "$services" ]; then
        log "WARNING" "Службы 1С не найдены в systemctl"
        # Проверяем процессы
        local processes=$(ps aux | grep -E "ragent|rmngr|rphost" | grep -v grep | wc -l)
        if [ "$processes" -gt 0 ]; then
            log "INFO" "Останавливаем процессы 1С напрямую..."
            pkill -f "ragent" 2>/dev/null
            pkill -f "rmngr" 2>/dev/null
            pkill -f "rphost" 2>/dev/null
            sleep 10
        fi
        return 0
    fi
    
    log "INFO" "Найдено служб: $(echo "$services" | wc -l)"
    
    # Останавливаем RAS службы (порты 1545, 1845, 1945...)
    for service in $services; do
        if [[ "$service" == *"-ras.service" ]] || [[ "$service" == *"ras"* ]]; then
            log "INFO" "  Останавливаем: $service"
            if systemctl stop "$service" 2>/dev/null; then
                log "SUCCESS" "    Остановлена"
            else
                log "WARNING" "    Ошибка остановки"
            fi
            sleep 2
        fi
    done
    
    # Останавливаем основные службы (порты 1540, 1840, 1940...)
    for service in $services; do
        if [[ "$service" != *"-ras.service" ]] && [[ "$service" != *"ras"* ]]; then
            log "INFO" "  Останавливаем: $service"
            if systemctl stop "$service" 2>/dev/null; then
                log "SUCCESS" "    Остановлена"
            else
                log "WARNING" "    Ошибка остановки"
            fi
            sleep 3
        fi
    done
    
    # Проверяем остановку
    sleep 5
    local running_procs=$(ps aux | grep -E "ragent|rmngr|rphost" | grep -v grep | wc -l)
    if [ "$running_procs" -eq 0 ]; then
        log "SUCCESS" "Все службы 1С остановлены"
    else
        log "WARNING" "Осталось процессов: $running_procs"
    fi
    
    # Очистка файлов блокировок
    local snc_files=$(find /home/usr1cv8 -name "snccntx*" -type f 2>/dev/null | wc -l)
    if [ "$snc_files" -gt 0 ]; then
        find /home/usr1cv8 -name "snccntx*" -type f -delete 2>/dev/null
        log "INFO" "Удалено файлов блокировок: $snc_files"
    fi
}

start_1c_services() {
    log "INFO" "Запуск служб 1С..."
    
    local services=$(systemctl list-unit-files --type=service 2>/dev/null | \
        grep -E "srv1c.*service" | awk '{print $1}')
    
    if [ -z "$services" ]; then
        log "WARNING" "Службы 1С не найдены"
        return 0
    fi
    
    # Запускаем основные службы
    for service in $services; do
        if [[ "$service" != *"-ras.service" ]] && [[ "$service" != *"ras"* ]]; then
            log "INFO" "  Запускаем: $service"
            if systemctl start "$service" 2>/dev/null; then
                log "SUCCESS" "    Запущена"
            else
                log "WARNING" "    Ошибка запуска"
            fi
            sleep 5
        fi
    done
    
    # Запускаем RAS службы
    for service in $services; do
        if [[ "$service" == *"-ras.service" ]] || [[ "$service" == *"ras"* ]]; then
            log "INFO" "  Запускаем: $service"
            if systemctl start "$service" 2>/dev/null; then
                log "SUCCESS" "    Запущена"
            else
                log "WARNING" "    Ошибка запуска"
            fi
            sleep 2
        fi
    done
    
    # Проверка запуска
    sleep 10
    local running_services=$(systemctl list-units --type=service --state=running | grep srv1c | wc -l)
    local running_procs=$(ps aux | grep -E "ragent|rmngr|rphost" | grep -v grep | wc -l)
    
    log "SUCCESS" "Запущено служб: $running_services, процессов: $running_procs"
}

# =================================================================
# ВЫПОЛНЕНИЕ БЭКАПА
# =================================================================
execute_backup() {
    local backup_log="$LOG_DIR/pg_probackup_$(date +%Y%m%d_%H%M%S).log"
    local start_time=$(date +%s)
    
    log "INFO" "Выполнение pg_probackup..."
    
    # Удаляем старый лог если есть
    [ -f "$LOG_DIR/pg_probackup.log" ] && rm -f "$LOG_DIR/pg_probackup.log"
    
    # Выполняем бэкап (ВАЖНО: используем export для PGPASSWORD)
    export PGPASSWORD="$PG_PASSWORD"
    
    if sudo -u postgres $PG_PROBACKUP backup \
        -B "$BACKUP_DIR" \
        --instance "$INSTANCE" \
        -U postgres \
        -d postgres \
        -h 127.0.0.1 \
        -b FULL \
        --stream \
        --compress \
        --expired \
        --delete-wal \
        --log-level-file=info \
        -j 4 > "$backup_log" 2>&1; then
        
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        # Проверяем что бэкап completed
        if grep -q "completed" "$backup_log"; then
            log "SUCCESS" "Бэкап успешно завершен за ${duration}с"
            
            # Получаем ID бэкапа
            local backup_id=$(grep "backup ID" "$backup_log" | tail -1 | awk '{print $4}' | tr -d ',')
            if [ -n "$backup_id" ]; then
                log "INFO" "ID бэкапа: $backup_id"
                echo "$backup_id" > /tmp/last_backup_id
            fi
            
            return 0
        else
            log "ERROR" "Бэкап выполнен, но нет статуса completed"
            return 1
        fi
    else
        log "ERROR" "Ошибка выполнения pg_probackup"
        log "INFO" "Последние строки лога:"
        tail -20 "$backup_log" | while read line; do
            log "ERROR" "  $line"
        done
        return 1
    fi
}

# =================================================================
# АРХИВАЦИЯ БЭКАПА
# =================================================================
archive_backup() {
    log "INFO" "Архивация бэкапа..."
    
    # Получаем последний бэкап
    local last_backup=$(sudo -u postgres ls "$BACKUP_DIR/backups/$INSTANCE" -t 2>/dev/null | head -1)
    
    if [ -z "$last_backup" ]; then
        log "ERROR" "Не найден бэкап для архивации"
        return 1
    fi
    
    # Проверяем что бэкап completed
    if ! sudo -u postgres grep -q "$last_backup completed" "$LOG_DIR/pg_probackup.log" 2>/dev/null; then
        log "ERROR" "Бэкап $last_backup не завершен"
        return 1
    fi
    
    local timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
    local archive_file="$COPY_DIR/pg_pro-$timestamp.tar.gz"
    
    log "INFO" "Создание архива: $archive_file"
    
    # Архивируем
    if sudo -u postgres tar -czf "$archive_file" \
        -C "$BACKUP_DIR/backups/$INSTANCE" \
        "$last_backup" \
        "pg_probackup.conf" > /dev/null 2>&1; then
        
        local size=$(ls -lh "$archive_file" | awk '{print $5}')
        log "SUCCESS" "Архив создан: $size"
        
        # MD5 сумма
        sudo -u postgres md5sum "$archive_file" > "${archive_file}.md5"
        log "INFO" "MD5 сумма создана"
        
        # Логируем
        echo "$(date '+%Y-%m-%d %H:%M:%S') создан $archive_file" >> "$COPY_DIR/copy.log"
        
        return 0
    else
        log "ERROR" "Ошибка создания архива"
        return 1
    fi
}

# =================================================================
# ЛОГИЧЕСКИЕ ДАМПЫ БАЗ
# =================================================================
logical_dumps() {
    log "INFO" "Создание логических дампов..."
    
    # Получаем список баз
    local databases=$(sudo -u postgres "$PG_PATH/psql" -qAt -c "
        SELECT datname 
        FROM pg_database 
        WHERE datname NOT IN ('postgres', 'template0', 'template1')
        ORDER BY datname;
    " 2>/dev/null)
    
    if [ -z "$databases" ]; then
        log "WARNING" "Базы данных не найдены"
        return 1
    fi
    
    local timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
    local success=0
    local total=0
    
    log "INFO" "Найдено баз: $(echo "$databases" | wc -l)"
    
    # Логируем начало
    echo "================================================" >> "$DUMP_DIR/backup.log"
    echo "Начало дампов: $(date '+%Y-%m-%d %H:%M:%S')" >> "$DUMP_DIR/backup.log"
    
    for db in $databases; do
        total=$((total + 1))
        log "INFO" "Дамп базы: $db"
        
        local dump_file="$DUMP_DIR/${db}_${timestamp}.dump"
        
        # Получаем размер базы
        local db_size=$(sudo -u postgres "$PG_PATH/psql" -t -c "
            SELECT pg_size_pretty(pg_database_size('$db'));
        " 2>/dev/null | tr -d ' ')
        
        log "INFO" "  Размер базы: $db_size"
        
        # Выполняем дамп
        if sudo -u postgres "$PG_PATH/pg_dump" -Fc "$db" > "$dump_file" 2>/dev/null; then
            local size=$(ls -lh "$dump_file" | awk '{print $5}')
            log "SUCCESS" "  Дамп создан: $size"
            
            # MD5 сумма
            sudo -u postgres md5sum "$dump_file" > "${dump_file}.md5"
            
            success=$((success + 1))
        else
            log "ERROR" "  Ошибка дампа базы $db"
            rm -f "$dump_file" 2>/dev/null
        fi
    done
    
    # Логируем результат
    echo "Дампы завершены: $(date '+%Y-%m-%d %H:%M:%S')" >> "$DUMP_DIR/backup.log"
    echo "Успешно: $success/$total" >> "$DUMP_DIR/backup.log"
    echo "================================================" >> "$DUMP_DIR/backup.log"
    
    if [ $success -eq $total ]; then
        log "SUCCESS" "Все дампы успешно созданы"
        return 0
    elif [ $success -gt 0 ]; then
        log "WARNING" "Создано $success/$total дампов"
        return 1
    else
        log "ERROR" "Не создано ни одного дампа"
        return 1
    fi
}

# =================================================================
# VACUUM БАЗ ДАННЫХ
# =================================================================
execute_vacuum() {
    log "INFO" "Выполнение VACUUM..."
    
    local vacuum_log="$BACKUP_DIR/vacuumdb_$(date +%Y%m%d_%H%M%S).txt"
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') VACUUM - начало" > "$vacuum_log"
    
    if sudo -u postgres "$PG_PATH/vacuumdb" -afz >> "$vacuum_log" 2>&1; then
        log "SUCCESS" "VACUUM успешно завершен"
        echo "$(date '+%Y-%m-%d %H:%M:%S') VACUUM - удачное завершение" >> "$vacuum_log"
    else
        log "ERROR" "VACUUM завершился с ошибкой"
        echo "$(date '+%Y-%m-%d %H:%M:%S') VACUUM - неудачное завершение" >> "$vacuum_log"
    fi
    
    # Сохраняем в общий лог
    cat "$vacuum_log" >> "$BACKUP_DIR/vacuumdb.log"
    
    # Отправка email если нужно
    if [ "$MAIL_ENABLED" = true ] && command -v mutt >/dev/null 2>&1; then
        cat "$vacuum_log" | mutt -s "VACUUM $(hostname) $(date '+%Y-%m-%d')" "$MAIL_TO"
    fi
    
    return 0
}

# =================================================================
# ПРОВЕРКА ЦЕЛОСТНОСТИ БЭКАПОВ
# =================================================================
validate_backups() {
    log "INFO" "Проверка целостности бэкапов..."
    
    local validate_log="$LOG_DIR/validate_$(date +%Y%m%d_%H%M%S).log"
    
    if sudo -u postgres $PG_PROBACKUP validate \
        -B "$BACKUP_DIR" \
        --instance "$INSTANCE" > "$validate_log" 2>&1; then
        
        log "SUCCESS" "Все бэкапы целостны"
        return 0
    else
        log "ERROR" "Найдены повреждённые бэкапы"
        log "INFO" "Последние строки лога:"
        tail -20 "$validate_log" | while read line; do
            log "ERROR" "  $line"
        done
        return 1
    fi
}

# =================================================================
# ОЧИСТКА СТАРЫХ АРХИВОВ
# =================================================================
cleanup_old() {
    log "INFO" "Очистка старых архивов (>$DAYS_KEEP дней)..."
    
    local deleted=0
    
    # Архивированные бэкапы
    local old_backups=$(find "$COPY_DIR" -name "*.tar.gz" -type f -mtime +$DAYS_KEEP 2>/dev/null)
    if [ -n "$old_backups" ]; then
        log "INFO" "Удаление архивов pg_probackup..."
        for file in $old_backups; do
            log "INFO" "  Удаляем: $(basename "$file")"
            rm -f "$file"
            rm -f "${file}.md5" 2>/dev/null
            deleted=$((deleted + 1))
        done
    fi
    
    # Логические дампы
    local old_dumps=$(find "$DUMP_DIR" -name "*.dump" -type f -mtime +$DAYS_KEEP 2>/dev/null)
    if [ -n "$old_dumps" ]; then
        log "INFO" "Удаление логических дампов..."
        for file in $old_dumps; do
            log "INFO" "  Удаляем: $(basename "$file")"
            rm -f "$file"
            rm -f "${file}.md5" 2>/dev/null
            deleted=$((deleted + 1))
        done
    fi
    
    # Старые логи (90 дней)
    local old_logs=$(find "$LOG_DIR" -name "*.log" -type f -mtime +90 2>/dev/null | wc -l)
    if [ "$old_logs" -gt 0 ]; then
        log "INFO" "Удаление старых логов..."
        find "$LOG_DIR" -name "*.log" -type f -mtime +90 -delete 2>/dev/null
        deleted=$((deleted + old_logs))
    fi
    
    if [ $deleted -gt 0 ]; then
        log "SUCCESS" "Удалено файлов: $deleted"
    else
        log "INFO" "Нет файлов для удаления"
    fi
}

# =================================================================
# ОТЧЁТ О СОСТОЯНИИ
# =================================================================
show_report() {
    echo ""
    echo "========================================"
    echo "ОТЧЁТ О СОСТОЯНИИ СИСТЕМЫ БЭКАПА"
    echo "========================================"
    echo "Время:        $(date)"
    echo "Система:      $(hostname)"
    echo "Режим:        $RUN_MODE"
    echo ""
    
    # Свободное место
    echo "1. СВОБОДНОЕ МЕСТО:"
    df -h "$BACKUP_DIR" | tail -1 | awk '{print "   " $1 ": " $3 "/" $2 " (" $5 " занято)"}'
    if [ "$BACKUP_DIR" != "$ARCHIVE_DIR" ]; then
        df -h "$ARCHIVE_DIR" | tail -1 | awk '{print "   " $1 ": " $3 "/" $2 " (" $5 " занято)"}'
    fi
    echo ""
    
    # PostgreSQL
    echo "2. POSTGRESQL:"
    if systemctl is-active postgrespro-1c-17 >/dev/null 2>&1; then
        echo "   ✅ Активен"
        
        # Размер баз
        echo "   Размеры баз:"
        sudo -u postgres "$PG_PATH/psql" -t -c "
            SELECT datname, pg_size_pretty(pg_database_size(datname))
            FROM pg_database 
            WHERE datname NOT IN ('template0', 'template1')
            ORDER BY pg_database_size(datname) DESC;
        " 2>/dev/null | while read line; do
            echo "     $line"
        done
    else
        echo "   ❌ Не активен"
    fi
    echo ""
    
    # Последние бэкапы
    echo "3. ПОСЛЕДНИЕ БЭКАПЫ:"
    sudo -u postgres $PG_PROBACKUP show -B "$BACKUP_DIR" --instance "$INSTANCE" 2>/dev/null | \
        tail -5 | while read line; do
        echo "   $line"
    done
    echo ""
    
    # Архивы
    echo "4. АРХИВЫ:"
    local pgp_count=$(find "$COPY_DIR" -name "*.tar.gz" -type f 2>/dev/null | wc -l)
    local pgp_newest=$(find "$COPY_DIR" -name "*.tar.gz" -type f -exec ls -t {} + 2>/dev/null | head -1)
    echo "   pg_probackup: $pgp_count файлов"
    if [ -n "$pgp_newest" ]; then
        echo "   Последний: $(date -r "$pgp_newest" '+%Y-%m-%d %H:%M')"
    fi
    
    local dump_count=$(find "$DUMP_DIR" -name "*.dump" -type f 2>/dev/null | wc -l)
    local dump_newest=$(find "$DUMP_DIR" -name "*.dump" -type f -exec ls -t {} + 2>/dev/null | head -1)
    echo "   pg_dump: $dump_count файлов"
    if [ -n "$dump_newest" ]; then
        echo "   Последний: $(date -r "$dump_newest" '+%Y-%m-%d %H:%M')"
    fi
    echo ""
    
    # Процессы 1С
    echo "5. ПРОЦЕССЫ 1С:"
    local proc_count=$(ps aux | grep -E "ragent|rmngr|rphost" | grep -v grep | wc -l)
    echo "   Активных процессов: $proc_count"
    echo ""
    
    echo "ГЛАВНЫЙ ЛОГ: $MAIN_LOG"
    echo "========================================"
}

# =================================================================
# ОСНОВНАЯ ЛОГИКА
# =================================================================
full_stop_backup() {
    log "INFO" "=== ПОЛНЫЙ БЭКАП С ОСТАНОВКОЙ 1С ==="
    
    # Проверки
    check_postgresql || return 1
    check_disk_space || return 1
    
    # 1. Остановка 1С
    stop_1c_services
    
    # 2. Выполнение бэкапа
    if execute_backup; then
        # 3. Запуск 1С
        start_1c_services
        
        # 4. Архивирование
        archive_backup
        
        # 5. Логические дампы
        logical_dumps
        
        # 6. VACUUM
        execute_vacuum
        
        log "SUCCESS" "ПОЛНЫЙ ЦИКЛ БЭКАПА ЗАВЕРШЕН УСПЕШНО"
    else
        log "ERROR" "ОШИБКА БЭКАПА, ЗАПУСКАЕМ 1С"
        start_1c_services
        return 1
    fi
}

full_hot_backup() {
    log "INFO" "=== ГОРЯЧИЙ БЭКАП БЕЗ ОСТАНОВКИ ==="
    
    # Проверки
    check_postgresql || return 1
    check_disk_space || return 1
    
    # Только бэкап
    execute_backup
}

# =================================================================
# ГЛАВНАЯ ФУНКЦИЯ
# =================================================================
main() {
    # Инициализация
    init
    
    # Обработка команд
    case "${1:-}" in
        "validate")
            validate_backups
            ;;
        "cleanup")
            cleanup_old
            ;;
        "report")
            show_report
            ;;
        *)
            # Автоматический режим
            case "$MODE" in
                "full-stop")
                    full_stop_backup
                    ;;
                "full-hot")
                    full_hot_backup
                    ;;
                *)
                    log "ERROR" "Неизвестный режим: $MODE"
                    return 1
                    ;;
            esac
            ;;
    esac
    
    # Финальное сообщение
    local duration=$(( $(date +%s) - ${START_TIME:-$(date +%s)} ))
    log "INFO" "Скрипт выполнен за ${duration} секунд"
    log "INFO" "Лог сохранен: $MAIN_LOG"
    
    # Отправка email если нужно
    if [ "$MAIL_ENABLED" = true ] && command -v mutt >/dev/null 2>&1; then
        local subject="Бэкап $(hostname) - $(date '+%Y-%m-%d %H:%M')"
        tail -50 "$MAIN_LOG" | mutt -s "$subject" "$MAIL_TO"
    fi
}

# =================================================================
# ЗАПУСК СКРИПТА
# =================================================================
# Запоминаем время старта
readonly START_TIME=$(date +%s)

# Проверяем что запускаем от root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}ОШИБКА: Скрипт должен запускаться от root${NC}"
    exit 1
fi

# Ловим сигналы прерывания
trap 'log "WARNING" "Скрипт прерван пользователем"; exit 1' INT TERM

# Запускаем
main "$@"

# Копируем лог в общий файл
cat "$MAIN_LOG" >> "$LOG_DIR/backup_all.log" 2>/dev/null

exit 0