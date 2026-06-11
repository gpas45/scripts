#!/bin/bash

# =============================================================================
# WAL-G Interactive Restore Script
# =============================================================================

set -euo pipefail

PGVER="${PGVER:-1c-18}"
CONFIG_DIR="/etc/wal-g.d"
CONFIG_PREFIX=".walg-"
CONFIG_SUFFIX=".json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_section() { echo -e "\n${CYAN}${BOLD}>>> $* ${NC}"; }

# =============================================================================
# Шаг 1: Выбор порта / конфига
# =============================================================================
log_section "Поиск конфигурационных файлов WAL-G"

mapfile -t CONFIG_FILES < <(find "$CONFIG_DIR" -maxdepth 1 -name "${CONFIG_PREFIX}*${CONFIG_SUFFIX}" 2>/dev/null | sort)

if [[ ${#CONFIG_FILES[@]} -eq 0 ]]; then
    log_error "Конфиги не найдены в $CONFIG_DIR"
    exit 1
fi

declare -a PORTS=()
for cfg in "${CONFIG_FILES[@]}"; do
    filename=$(basename "$cfg")
    port="${filename#${CONFIG_PREFIX}}"
    port="${port%${CONFIG_SUFFIX}}"
    PORTS+=("$port")
done

echo ""
echo -e "${BOLD}Доступные порты PostgreSQL:${NC}"
for i in "${!PORTS[@]}"; do
    echo -e "  ${CYAN}[$((i+1))]${NC} Порт: ${BOLD}${PORTS[$i]}${NC}  →  ${CONFIG_FILES[$i]}"
done
echo ""

while true; do
    read -rp "Выберите номер (1-${#PORTS[@]}): " CHOICE
    if [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= ${#PORTS[@]} )); then
        IDX=$((CHOICE - 1))
        PGPORT="${PORTS[$IDX]}"
        WALG_CONFIG_FILE="${CONFIG_FILES[$IDX]}"
        break
    fi
    log_warn "Некорректный ввод, попробуйте снова."
done

log_info "Выбран порт: ${BOLD}$PGPORT${NC}"
log_info "Конфиг:      ${BOLD}$WALG_CONFIG_FILE${NC}"

# =============================================================================
# Шаг 2: Определение PGDATA
# =============================================================================
log_section "Определение PGDATA"

RESTORE_PGDATA="/var/lib/pgpro/${PGVER}/data-${PGPORT}"
log_info "PGDATA по умолчанию: ${BOLD}$RESTORE_PGDATA${NC}"

read -rp "Использовать этот путь? [Y/n]: " CONFIRM_DATA
if [[ "${CONFIRM_DATA,,}" == "n" ]]; then
    read -rp "Введите путь PGDATA: " CUSTOM_DATA
    [[ -z "$CUSTOM_DATA" ]] && { log_error "Путь не может быть пустым."; exit 1; }
    RESTORE_PGDATA="$CUSTOM_DATA"
    log_info "Используется путь: ${BOLD}$RESTORE_PGDATA${NC}"
fi

# =============================================================================
# Шаг 3: Выбор точки восстановления
# =============================================================================
log_section "Точка восстановления"

echo -e "${BOLD}Доступные бэкапы:${NC}"
su - postgres -c "/usr/bin/wal-g backup-list --config $WALG_CONFIG_FILE" 2>/dev/null || {
    log_warn "Не удалось получить список бэкапов."
}
echo ""

echo -e "${BOLD}Варианты восстановления:${NC}"
echo -e "  ${CYAN}[1]${NC} LATEST (последний бэкап)"
echo -e "  ${CYAN}[2]${NC} Указать имя бэкапа вручную"
echo -e "  ${CYAN}[3]${NC} Восстановление до определённого времени (PITR)"
echo ""

while true; do
    read -rp "Выберите вариант [1-3]: " RESTORE_CHOICE
    case "$RESTORE_CHOICE" in
        1)
            BACKUP_NAME="LATEST"
            PITR_TARGET=""
            break
            ;;
        2)
            read -rp "Введите имя бэкапа: " BACKUP_NAME
            [[ -z "$BACKUP_NAME" ]] && { log_warn "Имя не может быть пустым."; continue; }
            PITR_TARGET=""
            break
            ;;
        3)
            BACKUP_NAME="LATEST"
            read -rp "Введите дату/время (формат: YYYY-MM-DD HH:MM:SS): " PITR_TARGET
            [[ -z "$PITR_TARGET" ]] && { log_warn "Время не может быть пустым."; continue; }
            break
            ;;
        *)
            log_warn "Некорректный ввод."
            ;;
    esac
done

# =============================================================================
# Шаг 4: Проверка сервиса и директории
# =============================================================================
log_section "Предварительные проверки"

SERVICE_NAME="postgresql-${PGVER}-${PGPORT}"

if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    log_warn "Сервис ${BOLD}$SERVICE_NAME${NC} запущен!"
    read -rp "Остановить сервис перед восстановлением? [Y/n]: " STOP_SVC
    if [[ "${STOP_SVC,,}" != "n" ]]; then
        log_info "Останавливаю $SERVICE_NAME..."
        systemctl stop "$SERVICE_NAME"
        log_info "Сервис остановлен."
    else
        log_error "Восстановление невозможно при запущенном сервисе."
        exit 1
    fi
else
    log_info "Сервис $SERVICE_NAME не запущен. ОК"
fi

if [[ -d "$RESTORE_PGDATA" ]]; then
    log_warn "Директория ${BOLD}$RESTORE_PGDATA${NC} существует и будет ПЕРЕЗАПИСАНА!"
    BACKUP_OLD="${RESTORE_PGDATA}.bak.$(date +%Y%m%d_%H%M%S)"
    read -rp "Создать резервную копию текущего PGDATA? [Y/n]: " BACKUP_EXISTING
    if [[ "${BACKUP_EXISTING,,}" != "n" ]]; then
        log_info "Переименовываю в $BACKUP_OLD ..."
        mv "$RESTORE_PGDATA" "$BACKUP_OLD"
        log_info "Готово: $BACKUP_OLD"
    else
        log_warn "Очищаю $RESTORE_PGDATA ..."
        rm -rf "$RESTORE_PGDATA"
    fi
fi

mkdir -p "$RESTORE_PGDATA"
chown postgres:postgres "$RESTORE_PGDATA"
chmod 700 "$RESTORE_PGDATA"
log_info "Директория подготовлена: $RESTORE_PGDATA"

# =============================================================================
# Шаг 5: Итоговое подтверждение
# =============================================================================
log_section "Итоговые параметры"

echo -e "  Порт:           ${BOLD}$PGPORT${NC}"
echo -e "  PGDATA:         ${BOLD}$RESTORE_PGDATA${NC}"
echo -e "  Конфиг WAL-G:   ${BOLD}$WALG_CONFIG_FILE${NC}"
echo -e "  Бэкап:          ${BOLD}$BACKUP_NAME${NC}"
[[ -n "${PITR_TARGET:-}" ]] && \
echo -e "  PITR до:        ${BOLD}$PITR_TARGET${NC}"
echo ""
log_warn "Все данные в $RESTORE_PGDATA будут ЗАМЕНЕНЫ!"
echo ""

read -rp "Введите YES для подтверждения: " FINAL_CONFIRM
if [[ "$FINAL_CONFIRM" != "YES" ]]; then
    log_warn "Отменено пользователем."
    exit 0
fi

# =============================================================================
# Шаг 6: Восстановление
# =============================================================================
LOG_DIR="${RESTORE_PGDATA}/log"
mkdir -p "$LOG_DIR"
chown postgres:postgres "$LOG_DIR"
LOG_FILE="${LOG_DIR}/wal-g-restore-${PGPORT}-$(date +%Y-%m-%d_%H-%M-%S).log"

log_section "Запуск WAL-G backup-fetch"
log_info "Лог: $LOG_FILE"

su - postgres -c "/usr/bin/wal-g backup-fetch \
    --config $WALG_CONFIG_FILE \
    $RESTORE_PGDATA \
    $BACKUP_NAME" 2>&1 | tee "$LOG_FILE"

log_info "backup-fetch завершён."

# =============================================================================
# Шаг 7: recovery.signal + recovery.conf (PITR)
# =============================================================================
log_section "Настройка recovery"

su - postgres -c "touch $RESTORE_PGDATA/recovery.signal"
log_info "Создан recovery.signal"

if [[ -n "${PITR_TARGET:-}" ]]; then
    RECOVERY_CONF="$RESTORE_PGDATA/postgresql.auto.conf"
    log_info "Добавляю PITR параметры в $RECOVERY_CONF"
    cat >> "$RECOVERY_CONF" <<EOF

# --- WAL-G PITR restore ---
recovery_target_time = '${PITR_TARGET}'
recovery_target_action = 'promote'
EOF
    log_info "PITR настроен до: $PITR_TARGET"
fi

chown -R postgres:postgres "$RESTORE_PGDATA"

# =============================================================================
# Шаг 8: Запуск сервиса
# =============================================================================
log_section "Запуск сервиса"

read -rp "Запустить $SERVICE_NAME сейчас? [Y/n]: " START_SVC
if [[ "${START_SVC,,}" != "n" ]]; then
    systemctl start "$SERVICE_NAME"
    sleep 3
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_info "${GREEN}Сервис $SERVICE_NAME успешно запущен!${NC}"
    else
        log_error "Сервис не запустился. Проверьте логи:"
        echo "  journalctl -u $SERVICE_NAME -n 50"
        echo "  tail -n 50 $RESTORE_PGDATA/log/postgresql-*.log"
        exit 1
    fi
else
    log_info "Запустите сервис вручную: systemctl start $SERVICE_NAME"
fi

log_section "Восстановление завершено"
log_info "Лог WAL-G: $LOG_FILE"
