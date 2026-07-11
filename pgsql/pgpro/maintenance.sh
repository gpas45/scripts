#!/usr/bin/env bash
set -euo pipefail

# =====================================================================
#  Регламентное обслуживание СУБД PostgreSQL / Postgres Pro (вариант 1С)
#
#  Стратегия:
#    * маленькая БД (< LIMIT_BYTES) — целиком VACUUM (FULL, ANALYZE)
#      (осознанно: маленькая база обрабатывается быстро);
#    * большая БД (>= LIMIT_BYTES) — ANALYZE по базе, затем выборочно
#      по распухшим таблицам (dead_pct > THRESHOLD_PCT):
#        - таблица <= MAX_TBL_BYTES  -> VACUUM FULL;
#        - таблица  > MAX_TBL_BYTES  -> pg_repack (онлайн, без ACCESS
#          EXCLUSIVE-лока), если он установлен;
#    * контроль возраста транзакций (защита от wraparound): при высоком
#      age(relfrozenxid) выполняется точечный VACUUM (FREEZE).
#
#  Особенности реализации:
#    * пропуск реплик (pg_is_in_recovery);
#    * защита от параллельного запуска (flock);
#    * lock_timeout, чтобы не выстраивать очередь блокировок под 1С;
#    * проверка свободного места перед перестроением таблиц;
#    * сбой на одном инстансе/БД/таблице не прерывает обслуживание
#      остальных (итоговый код возврата отражает наличие ошибок).
# =====================================================================

# --- настройки ---
PGHOST="localhost"
PGUSER="postgres"
TIMEOUT=3
RETENTION_DAYS=30
LIMIT_BYTES=$((10*1024*1024*1024))  # 10GB
MIN_TBL_BYTES=$((1*1024*1024))      # 1MB
MAX_TBL_BYTES=$((3*1024*1024*1024)) # 3GB

# VACUUM FULL по таблице, если доля мёртвых строк > THRESHOLD_PCT
THRESHOLD_PCT=30

# lock_timeout для сессий обслуживания: если ACCESS EXCLUSIVE-лок не
# удаётся взять за это время, операция отменяется и не копит очередь.
LOCK_TIMEOUT="${PG_MAINT_LOCK_TIMEOUT:-15s}"

# Порог возраста транзакций (из ~2.1 млрд) для точечного FREEZE / warning.
AGE_WARN=1500000000

# Свободного места должно быть не меньше, чем размер объекта * FACTOR
# (VACUUM FULL / pg_repack пересоздают таблицу и индексы).
FREE_SPACE_FACTOR=2

# Защита от одновременного запуска.
LOCKFILE="${PG_MAINT_LOCKFILE:-/tmp/pg_maintenance.lock}"

# Необязательный общий лог всего запуска (помимо per-instance логов).
RUNLOG="${PG_MAINT_RUNLOG:-}"

# lock_timeout применяется ко всем psql-сессиям обслуживания.
export PGOPTIONS="-c lock_timeout=${LOCK_TIMEOUT}"

# --- утилиты ---
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: need '$1'"; exit 1; }; }
need_cmd ss
need_cmd pg_isready
need_cmd psql
need_cmd find
need_cmd flock
need_cmd awk

HAVE_PG_REPACK=0
if command -v pg_repack >/dev/null 2>&1; then HAVE_PG_REPACK=1; fi

ts()  { date '+%F %T'; }
log() { echo "[$(ts)] $*"; }

# Порты слушающих экземпляров PostgreSQL. Берём именно поле локального
# адреса (Local Address:Port) и порт после последнего ':', чтобы не
# зацепить мусор из IPv6-адресов (напр. '::1') или из поля процесса.
ports() {
  ss -tlnpH 2>/dev/null \
  | awk '/"postgres"|"postmaster"/ { n = split($4, a, ":"); print a[n] }' \
  | sort -un
}

psql_sys() {
  local port="$1"; shift
  psql -h "$PGHOST" -p "$port" -U "$PGUSER" -d postgres -X -v ON_ERROR_STOP=1 "$@"
}

psql_db() {
  local port="$1" db="$2"; shift 2
  psql -h "$PGHOST" -p "$port" -U "$PGUSER" -d "$db" -X -v ON_ERROR_STOP=1 "$@"
}

# Доступно байт на файловой системе указанного пути.
avail_bytes() { df -P -k "$1" 2>/dev/null | awk 'NR==2 {print $4 * 1024}'; }

# have_space <path> <needed_bytes>: хватает ли места. Если определить не
# удалось — не блокируем операцию (возвращаем успех).
have_space() {
  local avail; avail="$(avail_bytes "$1")"
  [[ -z "$avail" ]] && return 0
  (( avail >= $2 ))
}

# --- операции над таблицей (все возвращают 0 при успехе) ---

# Точечный VACUUM FULL + сброс счётчиков + ANALYZE.
vacuum_full_table() {
  local port="$1" db="$2" schema="$3" table="$4" size="$5"
  local fqtn="\"${schema}\".\"${table}\""
  local need=$(( size * FREE_SPACE_FACTOR ))

  if ! have_space "$PGDATA" "$need"; then
    log "[$port/$db] WARN: недостаточно места для VACUUM FULL $fqtn (нужно ~${need}B), пропуск"
    return 1
  fi

  log "[$port/$db] VACUUM FULL $fqtn (size=${size}B)"
  if ! psql_db "$port" "$db" -c "VACUUM (FULL) ${fqtn};"; then
    log "[$port/$db] WARN: VACUUM FULL $fqtn не выполнен, продолжаем"
    return 1
  fi
  psql_db "$port" "$db" -c "SELECT pg_stat_reset_single_table_counters('\"${schema}\".\"${table}\"'::regclass);" || true
  psql_db "$port" "$db" -c "ANALYZE ${fqtn};" || true
  return 0
}

# Онлайн-перестроение большой таблицы через pg_repack.
repack_table() {
  local port="$1" db="$2" schema="$3" table="$4" size="$5"
  local fqtn="\"${schema}\".\"${table}\""
  local need=$(( size * FREE_SPACE_FACTOR ))

  if (( ! HAVE_PG_REPACK )); then
    log "[$port/$db] WARN: таблица $fqtn > ${MAX_TBL_BYTES}B, но pg_repack не установлен, пропуск"
    return 1
  fi
  local has_ext
  has_ext="$(psql_db "$port" "$db" -Atc "SELECT 1 FROM pg_extension WHERE extname='pg_repack';" || true)"
  if [[ "$has_ext" != "1" ]]; then
    log "[$port/$db] WARN: расширение pg_repack не создано в БД (CREATE EXTENSION pg_repack;), пропуск $fqtn"
    return 1
  fi
  if ! have_space "$PGDATA" "$need"; then
    log "[$port/$db] WARN: недостаточно места для pg_repack $fqtn (нужно ~${need}B), пропуск"
    return 1
  fi

  log "[$port/$db] pg_repack ${schema}.${table} (size=${size}B, онлайн)"
  if ! pg_repack -h "$PGHOST" -p "$port" -U "$PGUSER" -d "$db" \
        -t "${schema}.${table}" --wait-timeout=60 2>&1; then
    log "[$port/$db] WARN: pg_repack $fqtn завершился с ошибкой, продолжаем"
    return 1
  fi
  psql_db "$port" "$db" -c "SELECT pg_stat_reset_single_table_counters('\"${schema}\".\"${table}\"'::regclass);" || true
  psql_db "$port" "$db" -c "ANALYZE ${fqtn};" || true
  return 0
}

# Точечный FREEZE против wraparound.
freeze_table() {
  local port="$1" db="$2" schema="$3" table="$4" age="$5"
  local fqtn="\"${schema}\".\"${table}\""
  log "[$port/$db] age(relfrozenxid)=${age} > ${AGE_WARN}: VACUUM (FREEZE) $fqtn"
  psql_db "$port" "$db" -c "VACUUM (FREEZE, ANALYZE) ${fqtn};" \
    || log "[$port/$db] WARN: VACUUM FREEZE $fqtn не выполнен, продолжаем"
}

# --- обслуживание одной большой БД (выборочно по таблицам) ---
maintain_big_db() {
  local port="$1" db="$2"
  local rc=0

  log "[$port/$db] ANALYZE (database)"
  psql_db "$port" "$db" -c "ANALYZE;" || { log "[$port/$db] WARN: ANALYZE не выполнен"; rc=1; }

  # schema|table|total_size_bytes|live|dead|xid_age
  # Размер считаем один раз в подзапросе; верхнюю границу здесь не режем —
  # выбор VACUUM FULL vs pg_repack делаем ниже по size.
  local rows
  if ! rows="$(psql_db "$port" "$db" -Atc "
    SELECT schemaname, relname, total, live, dead, xid_age
    FROM (
      SELECT s.schemaname,
             s.relname,
             pg_total_relation_size(s.relid) AS total,
             COALESCE(s.n_live_tup, 0)       AS live,
             COALESCE(s.n_dead_tup, 0)       AS dead,
             age(c.relfrozenxid)             AS xid_age
      FROM pg_stat_user_tables s
      JOIN pg_class c ON c.oid = s.relid
    ) t
    WHERE total >= ${MIN_TBL_BYTES}
    ORDER BY total DESC;
  ")"; then
    log "[$port/$db] WARN: не удалось получить список таблиц, пропуск БД"
    return 1
  fi

  [[ -z "$rows" ]] && return "$rc"

  local schema table size live dead xid_age total dead_pct handled
  while IFS='|' read -r schema table size live dead xid_age; do
    [[ -z "$schema" ]] && continue

    total=$(( live + dead ))
    dead_pct=0
    (( total > 0 )) && dead_pct=$(( dead * 100 / total ))

    handled=0
    if (( dead_pct > THRESHOLD_PCT )); then
      log "[$port/$db] Table \"$schema\".\"$table\" size=${size}B live=$live dead=$dead => dead_pct=${dead_pct}% > ${THRESHOLD_PCT}%"
      if (( size <= MAX_TBL_BYTES )); then
        vacuum_full_table "$port" "$db" "$schema" "$table" "$size" && handled=1 || rc=1
      else
        repack_table "$port" "$db" "$schema" "$table" "$size" && handled=1 || rc=1
      fi
    fi

    # Если распухание не отрабатывали (или не смогли), но возраст
    # транзакций высок — точечный FREEZE (FULL/repack сами замораживают).
    if (( ! handled )) && (( xid_age > AGE_WARN )); then
      freeze_table "$port" "$db" "$schema" "$table" "$xid_age"
    fi
  done <<< "$rows"

  return "$rc"
}

# --- обслуживание одного экземпляра (порт) ---
# Печатает в stdout — вызывающая сторона направляет вывод в per-instance
# лог через tee. Возвращает 0, если ошибок обслуживания не было.
maintain_instance() {
  local port="$1"
  local rc=0

  log "Port=$port PGDATA=$PGDATA"

  # Предупреждения о приближении wraparound на уровне БД.
  local wrap
  wrap="$(psql_sys "$port" -Atc "
    SELECT datname || ' age=' || age(datfrozenxid)
    FROM pg_database
    WHERE datallowconn AND age(datfrozenxid) > ${AGE_WARN}
    ORDER BY age(datfrozenxid) DESC;" || true)"
  if [[ -n "$wrap" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && log "WARN: приближение wraparound: $line"
    done <<< "$wrap"
  fi

  # Единый список БД с размерами; бакетируем по LIMIT_BYTES в bash.
  local dblist
  if ! dblist="$(psql_sys "$port" -Atc "
    SELECT datname, pg_database_size(datname)
    FROM pg_database
    WHERE datallowconn
      AND NOT datistemplate
      AND datname <> 'postgres';")"; then
    log "WARN: не удалось получить список БД для порта $port"
    return 1
  fi

  local -a DB_VF=() DB_VF_SIZE=() DB_SC=()
  local name size
  while IFS='|' read -r name size; do
    [[ -z "$name" ]] && continue
    if (( size < LIMIT_BYTES )); then
      DB_VF+=("$name"); DB_VF_SIZE+=("$size")
    else
      DB_SC+=("$name")
    fi
  done <<< "$dblist"

  log "DB_VF (<10GB): ${DB_VF[*]:-none}"
  log "DB_SC (>=10GB): ${DB_SC[*]:-none}"

  # DB_VF: целиком VACUUM (FULL, ANALYZE) — быстро для маленьких БД.
  local i db
  for i in "${!DB_VF[@]}"; do
    db="${DB_VF[$i]}"; size="${DB_VF_SIZE[$i]}"
    local need=$(( size * FREE_SPACE_FACTOR ))
    if ! have_space "$PGDATA" "$need"; then
      log "[$port/$db] WARN: недостаточно места для VACUUM FULL БД (нужно ~${need}B), пропуск"
      rc=1; continue
    fi
    log "[$port/$db] VACUUM FULL + ANALYZE (database, size=${size}B)"
    psql_db "$port" "$db" -c "VACUUM (FULL, ANALYZE);" \
      || { log "[$port/$db] WARN: VACUUM FULL БД не выполнен, продолжаем"; rc=1; }
  done

  # DB_SC: выборочно по таблицам.
  for db in "${DB_SC[@]:-}"; do
    [[ -z "$db" ]] && continue
    maintain_big_db "$port" "$db" || rc=1
  done

  log "=== Done port $port ==="
  return "$rc"
}

# --- основной проход по портам ---
run() {
  local overall=0
  local PGPORT

  for PGPORT in $(ports); do
    log "=== Checking instance on port $PGPORT ==="

    if ! pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -t "$TIMEOUT" >/dev/null 2>&1; then
      log "Port $PGPORT: not ready, skip"
      continue
    fi

    # Пропускаем реплики: VACUUM/ANALYZE в recovery невозможны.
    local in_recovery
    in_recovery="$(psql_sys "$PGPORT" -Atc "SELECT pg_is_in_recovery();" 2>/dev/null || true)"
    if [[ "$in_recovery" == "t" ]]; then
      log "Port $PGPORT: standby (recovery), skip"
      continue
    fi

    PGDATA="$(psql_sys "$PGPORT" -Atc "SHOW data_directory;" 2>/dev/null || true)"
    if [[ -z "${PGDATA}" ]]; then
      log "ERROR: cannot get data_directory for port $PGPORT, skip"
      overall=1; continue
    fi

    local LOGDIR="${PGDATA}/log"
    if [[ ! -d "$LOGDIR" ]]; then
      log "ERROR: log dir '$LOGDIR' not found for port $PGPORT, skip"
      overall=1; continue
    fi

    local today; today="$(date +%F)"
    local LOGFILE="${LOGDIR}/maint_${PGPORT}_${today}.log"

    # Ротация: удаляем старые логи этого скрипта.
    find "$LOGDIR" -maxdepth 1 -type f -name 'maint_*.log' -mtime +"$RETENTION_DAYS" -print -delete 2>/dev/null || true

    # Обслуживание инстанса — вывод дублируем в per-instance лог.
    # Через PIPESTATUS ловим код возврата, не роняя errexit.
    set +e
    maintain_instance "$PGPORT" 2>&1 | tee -a "$LOGFILE"
    local rc=${PIPESTATUS[0]}
    set -e
    (( rc != 0 )) && overall=1
  done

  return "$overall"
}

# --- запуск с защитой от параллельного выполнения ---
main() {
  exec 9>"$LOCKFILE"
  if ! flock -n 9; then
    log "Уже выполняется (lock $LOCKFILE), выход"
    exit 0
  fi
  run
}

if [[ -n "$RUNLOG" ]]; then
  main 2>&1 | tee -a "$RUNLOG"
  exit "${PIPESTATUS[0]}"
else
  main
fi
