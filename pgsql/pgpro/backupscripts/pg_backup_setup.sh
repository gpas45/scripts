#!/bin/bash
# Скрипт инициализации конфигурации бэкапа PostgreSQL

set -o errexit
set -o nounset

CONFIG_DIR="/var/lib/pgpro/_backup/scripts"
CONFIG_FILE="${CONFIG_DIR}/pg_backup.conf"
DB_LIST_FILE="${CONFIG_DIR}/db_list.txt"

# Создаем директории если не существуют
mkdir -p "${CONFIG_DIR}" "/var/lib/pgpro/_backup/DB" "/var/lib/pgpro/_backup/logs"

# Создаем конфигурационный файл
cat > "${CONFIG_FILE}" <<'EOF'
#!/bin/bash
# Конфигурация скрипта бэкапа PostgreSQL

### ПУТИ ###
SCRIPT_DIR="/var/lib/pgpro/_backup/scripts"
BACKUP_DIR="/var/lib/pgpro/_backup/DB"
LOG_DIR="/var/lib/pgpro/_backup/logs"

### POSTGRESQL ###
PG_HOST="localhost"
PG_PORT="5432"
PG_USER="postgres"
DB_LIST_FILE="${SCRIPT_DIR}/db_list.txt"  # Файл со списком БД

### ЛОГИРОВАНИЕ ###
LOG_LEVEL="error"          # error|warning|info|debug
LOG_RETENTION_DAYS=30     # Дней хранения логов

### УВЕДОМЛЕНИЯ ###
NOTIFY_ENABLED=false      # true|false
NOTIFY_EMAIL=""
NOTIFY_FROM=""

### НАСТРОЙКИ БЭКАПА ###
COMPRESSION_LEVEL=6       # Уровень сжатия (1-9)
BACKUP_RETENTION=7        # Дней хранения бэкапов
EOF

# Создаем файл со списком БД
cat > "${DB_LIST_FILE}" <<'EOF'
# Список баз данных для бэкапа
# По одной БД на строку в формате: db_name
# example_db
EOF

# Устанавливаем права
chmod 600 "${CONFIG_FILE}"
chmod 600 "${DB_LIST_FILE}"

echo "Конфигурация создана:"
echo " - Основной конфиг: ${CONFIG_FILE}"
echo " - Список БД: ${DB_LIST_FILE}"
echo "Перед использованием отредактируйте эти файлы"
