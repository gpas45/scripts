#!/usr/bin/env bash
set -euo pipefail

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

# --- утилиты ---
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: need '$1'"; exit 1; }; }
need_cmd ss
need_cmd pg_isready
need_cmd psql
need_cmd find

ports() {
  ss -tlnp 2>/dev/null \
  | grep postgres \
  | grep -oP ':\d+' \
  | grep -oP '\d+' \
  | sort -u
}

psql_sys() {
  local port="$1"; shift
  psql -h "$PGHOST" -p "$port" -U "$PGUSER" -d postgres -X -v ON_ERROR_STOP=1 "$@"
}

psql_db() {
  local port="$1" db="$2"; shift 2
  psql -h "$PGHOST" -p "$port" -U "$PGUSER" -d "$db" -X -v ON_ERROR_STOP=1 "$@"
}

ts() { date '+%F %T'; }

# --- основной цикл по портам ---
for PGPORT in $(ports); do
  echo "[$(ts)] === Checking instance on port $PGPORT ==="

  if ! pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -t "$TIMEOUT" >/dev/null 2>&1; then
    echo "[$(ts)] Port $PGPORT: not ready, skip"
    continue
  fi

  PGDATA="$(psql_sys "$PGPORT" -Atc "SHOW data_directory;")"
  if [[ -z "${PGDATA}" ]]; then
    echo "[$(ts)] ERROR: cannot get data_directory for port $PGPORT"
    exit 1
  fi

  LOGDIR="${PGDATA}/log"
  if [[ ! -d "$LOGDIR" ]]; then
    echo "[$(ts)] ERROR: log dir '$LOGDIR' not found for port $PGPORT (stop)"
    exit 1
  fi

  LOGFILE="${LOGDIR}/maint_${PGPORT}_$(date +%F).log"
  exec > >(tee -a "$LOGFILE") 2>&1

  echo "[$(ts)] Port=$PGPORT PGDATA=$PGDATA LOGFILE=$LOGFILE"

  # ротация: удаляем файлы старше RETENTION_DAYS
  find "$LOGDIR" -maxdepth 1 -type f -name 'maint_*.log' -mtime +"$RETENTION_DAYS" -print -delete || true

  # --- списки баз ---
  mapfile -t DB_VF < <(psql_sys "$PGPORT" -Atc "
    SELECT datname
    FROM pg_database
    WHERE datallowconn
      AND NOT datistemplate
      AND datname <> 'postgres'
      AND pg_database_size(datname) < ${LIMIT_BYTES};
  ")

  mapfile -t DB_SC < <(psql_sys "$PGPORT" -Atc "
    SELECT datname
    FROM pg_database
    WHERE datallowconn
      AND NOT datistemplate
      AND datname <> 'postgres'
      AND pg_database_size(datname) >= ${LIMIT_BYTES};
  ")

  if ((${#DB_VF[@]})); then
    echo "[$(ts)] DB_VF (<10GB): ${DB_VF[*]}"
  else
    echo "[$(ts)] DB_VF (<10GB): none"
  fi

  if ((${#DB_SC[@]})); then
    echo "[$(ts)] DB_SC (>=10GB): ${DB_SC[*]}"
  else
    echo "[$(ts)] DB_SC (>=10GB): none"
  fi

  # --- DB_VF: VACUUM FULL + ANALYZE ---
  for db in "${DB_VF[@]:-}"; do
    [[ -z "$db" ]] && continue
    echo "[$(ts)] [$PGPORT/$db] VACUUM FULL + ANALYZE (database)"
    psql_db "$PGPORT" "$db" -c "VACUUM (FULL, ANALYZE);"
  done

  # --- DB_SC: ANALYZE, затем таблицы 1MB..3GB и выборочный VACUUM FULL ---
  for db in "${DB_SC[@]:-}"; do
    [[ -z "$db" ]] && continue

    echo "[$(ts)] [$PGPORT/$db] ANALYZE (database)"
    psql_db "$PGPORT" "$db" -c "ANALYZE;"

    # schema|table|total_size_bytes|live|dead
    mapfile -t candidates < <(psql_db "$PGPORT" "$db" -Atc "
      SELECT
        schemaname,
        relname,
        pg_total_relation_size(relid) AS total_size_bytes,
        COALESCE(n_live_tup,0) AS n_live_tup,
        COALESCE(n_dead_tup,0) AS n_dead_tup
      FROM pg_stat_user_tables
      WHERE pg_total_relation_size(relid) BETWEEN ${MIN_TBL_BYTES} AND ${MAX_TBL_BYTES}
      ORDER BY pg_total_relation_size(relid) DESC;
    ")

    for row in "${candidates[@]:-}"; do
      [[ -z "$row" ]] && continue
      IFS='|' read -r schema table size_bytes live dead <<< "$row"

      total=$((live + dead))
      if (( total <= 0 )); then
        continue
      fi

      # dead_pct = dead / (live+dead) * 100 (целочисленно)
      dead_pct=$(( dead * 100 / total ))

      if (( dead_pct > THRESHOLD_PCT )); then
        fqtn="\"${schema}\".\"${table}\""
        echo "[$(ts)] [$PGPORT/$db] Table $fqtn size=${size_bytes}B live=$live dead=$dead => dead_pct=${dead_pct}% > ${THRESHOLD_PCT}%: VACUUM FULL"

        psql_db "$PGPORT" "$db" -c "VACUUM (FULL) ${fqtn};"
        psql_db "$PGPORT" "$db" -c "SELECT pg_stat_reset_single_table_counters('${schema}.${table}'::regclass);"
        psql_db "$PGPORT" "$db" -c "ANALYZE ${fqtn};"
      fi
    done
  done

  echo "[$(ts)] === Done port $PGPORT ==="
done
