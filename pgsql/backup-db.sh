#!/bin/bash
# Бэкап и обслуживание баз данных PostgreSQL / Postgres Pro.
# Объединяет прежние backup-db-1c.sh и backup-db-pgsql.sh.
# Настройки переопределяются в конфиге: /etc/backup-pg.conf
# или путь к конфигу первым аргументом (см. backup-pg.conf.example).
set -euo pipefail

# --- Настройки по умолчанию ---
PGBIN=""                                  # каталог бинарников; пусто = из PATH (Postgres Pro 1C: /opt/pgpro/1c-14/bin)
BASES="/var/lib/pgpro/scripts/DB"         # файл со списком БД, по одной на строку
LOGS="/var/lib/pgpro/service_logs"        # каталог логов
BACKUPDIR="/var/lib/backup/pgpro"         # каталог бэкапов
KEEP=28                                   # сколько последних бэкапов хранить для каждой БД
LOGKEEP_DAYS=60                           # сколько дней хранить логи
TIMESTAMP_FILE="/var/log/timestamp"       # файл-отметка для мониторинга

CONF="${1:-/etc/backup-pg.conf}"
if [[ -f "$CONF" ]]; then
	# shellcheck source=/dev/null
	. "$CONF"
fi

DATA="$(date +%Y-%m-%d_%H-%M)"
LOGFILE="$LOGS/$DATA.log"

log()
{
	echo "$(date +%Y-%m-%d_%H-%M-%S)" "$*" >> "$LOGFILE"
}

# Выполнить команду PostgreSQL от пользователя postgres
pg()
{
	local cmd="$1"; shift
	[[ -n "$PGBIN" ]] && cmd="$PGBIN/$cmd"
	if [[ "$EUID" -eq 0 ]]; then
		sudo -u postgres "$cmd" "$@"
	else
		"$cmd" "$@"
	fi
}

Backup()
{
	local db="$1"
	local out="$BACKUPDIR/$DATA-$db.sql.gz"
	log "Старт резервного копирования" "$db"
	# pipefail гарантирует, что ошибка pg_dump не потеряется за pigz;
	# gzip -t отлавливает битый архив
	if pg pg_dump -U postgres "$db" 2>>"$LOGFILE" | pigz > "$out" && gzip -t "$out" 2>>"$LOGFILE"; then
		log "Резервное копирование закончено" "$db"
		return 0
	else
		log "Ошибка создания резервной копии" "$db"
		rm -f -- "$out"
		return 1
	fi
}

Maintenance()
{
	local db="$1"
	if [[ "$(date +%u)" -eq 6 ]]; then
		# VACUUM FULL перестраивает и индексы, отдельный reindexdb не нужен
		log "Старт vacuumdb FULL" "$db"
		if pg vacuumdb --full --analyze --username postgres --dbname "$db" >>"$LOGFILE" 2>&1; then
			log "Конец vacuumdb FULL" "$db"
		else
			log "Ошибка vacuumdb FULL" "$db"
			return 1
		fi
	else
		log "Старт vacuumdb" "$db"
		if pg vacuumdb --analyze --username postgres --dbname "$db" >>"$LOGFILE" 2>&1; then
			log "Конец vacuumdb" "$db"
		else
			log "Ошибка vacuumdb" "$db"
			return 1
		fi
	fi
}

ClearOldFiles()
{
	local db="$1"
	# Удаляем бэкапы этой БД сверх KEEP последних (по времени изменения)
	find "$BACKUPDIR" -maxdepth 1 -type f -name "*-$db.sql.gz" -printf '%T@ %p\n' \
		| sort -rn | tail -n +"$((KEEP + 1))" | cut -d' ' -f2- \
		| while IFS= read -r f; do
			rm -f -- "$f"
			log "Удалён старый бэкап" "${f##*/}"
		done
	# Логи чистим по возрасту
	find "$LOGS" -maxdepth 1 -type f -name "*.log" -mtime +"$LOGKEEP_DAYS" -delete
}

# --- Проверки ---
mkdir -p "$BACKUPDIR" "$LOGS"
if [[ ! -f "$BASES" ]]; then
	log "Ошибка, файл со списком БД для резервного копирования $BASES не найден."
	exit 1
fi

# --- Основной цикл ---
rc=0
while IFS= read -r db; do
	[[ -z "$db" || "$db" == \#* ]] && continue
	if Backup "$db"; then
		Maintenance "$db" || rc=1
		ClearOldFiles "$db"
	else
		rc=1
	fi
done < "$BASES"

if [[ "$rc" -eq 0 ]]; then
	date +%Y-%m-%d_%H-%M > "$TIMESTAMP_FILE"
	log "Создание файла для мониторинга"
else
	log "Завершено с ошибками"
fi
exit "$rc"
