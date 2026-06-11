#!/bin/bash
# Интерактивный скрипт восстановления PostgreSQL из бэкапа

# Проверка пользователя
if [ "$(whoami)" != "postgres" ]; then
    echo "ОШИБКА: Скрипт должен запускаться от пользователя postgres!" >&2
    exit 1
fi

# Пути и настройки
BACKUP_DIR="/var/lib/pgpro/_backup/DB"
LOG_DIR="/var/lib/pgpro/_backup/logs"
PGPASSFILE="$HOME/.pgpass"
RESTORE_LOG="$LOG_DIR/restore_$(date +%Y-%m-%d_%H-%M-%S).log"

# Функции
log() {
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $message" | tee -a "$RESTORE_LOG"
}

error_exit() {
    local msg="$1"
    log "ОШИБКА: $msg"
    exit 1
}

check_pg_connection() {
    if ! psql -lqt >/dev/null 2>&1; then
        error_exit "Не удалось подключиться к PostgreSQL"
    fi
}

list_backups() {
    log "Доступные резервные копии:"
    local i=1
    for backup in $(ls -1t "$BACKUP_DIR"/*.dump 2>/dev/null); do
        local size=$(du -h "$backup" | cut -f1)
        local mtime=$(stat -c %y "$backup" | cut -d'.' -f1)
        printf "  %2d) %s (%s, %s)\n" "$i" "$(basename "$backup")" "$size" "$mtime"
        backup_list[$i]=$backup
        ((i++))
    done
    
    [ ${#backup_list[@]} -eq 0 ] && error_exit "Резервные копии не найдены в $BACKUP_DIR"
}

select_backup() {
    read -p "Выберите номер бэкапа для восстановления: " backup_num
    
    if ! [[ "$backup_num" =~ ^[0-9]+$ ]] || [ -z "${backup_list[$backup_num]}" ]; then
        error_exit "Некорректный выбор"
    fi
    
    selected_backup="${backup_list[$backup_num]}"
    log "Выбран бэкап: $selected_backup"
}

get_db_name_from_backup() {
    local backup="$1"
    basename "$backup" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}-(.*)\.dump$/\1/'
}

list_databases() {
    log "Существующие базы данных:"
    psql -lqt | cut -d \| -f 1 | tr -d ' ' | grep -v -E 'template[0-9]|postgres' | nl
}

restore_database() {
    local backup_file="$1"
    local db_name="$2"
    local target_db="$3"
    
    log "Начало восстановления $db_name в $target_db"
    
    # Удаление существующей БД (если требуется)
    if psql -lqt | cut -d \| -f 1 | grep -qw "$target_db"; then
        read -p "База данных $target_db уже существует. Удалить её? [y/N] " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            log "Удаление базы данных $target_db..."
            dropdb "$target_db" || error_exit "Не удалось удалить базу данных $target_db"
        else
            error_exit "Восстановление отменено"
        fi
    fi
    
    # Создание новой БД
    log "Создание базы данных $target_db..."
    createdb "$target_db" || error_exit "Не удалось создать базу данных $target_db"
    
    # Восстановление
    log "Восстановление данных из $backup_file в $target_db..."
    if pg_restore -d "$target_db" "$backup_file"; then
        log "Восстановление успешно завершено!"
        
        # Анализ восстановленной БД
        log "Выполнение ANALYZE для восстановленной БД..."
        psql -d "$target_db" -c "ANALYZE;" || log "WARNING" "Не удалось выполнить ANALYZE"
    else
        error_exit "Ошибка при восстановлении базы данных"
    fi
}

# Основной процесс
check_pg_connection
list_backups
select_backup

original_db=$(get_db_name_from_backup "$selected_backup")
log "Исходное имя базы данных в бэкапе: $original_db"

echo "Варианты восстановления:"
echo "  1) Восстановить в новую базу данных с тем же именем ($original_db)"
echo "  2) Восстановить в существующую базу данных"
echo "  3) Восстановить в базу данных с другим именем"
read -p "Выберите вариант (1-3): " restore_option

case $restore_option in
    1)
        target_db="$original_db"
        ;;
    2)
        list_databases
        read -p "Введите имя существующей БД для восстановления: " target_db
        ;;
    3)
        read -p "Введите новое имя для восстановленной БД: " target_db
        ;;
    *)
        error_exit "Некорректный выбор"
        ;;
esac

# Подтверждение
echo
echo "Параметры восстановления:"
echo "  Бэкап:    $selected_backup"
echo "  Исходная: $original_db"
echo "  Целевая:  $target_db"
read -p "Подтвердить восстановление? [y/N] " confirm

if [[ "$confirm" =~ ^[Yy]$ ]]; then
    restore_database "$selected_backup" "$original_db" "$target_db"
else
    log "Восстановление отменено"
fi

exit 0
