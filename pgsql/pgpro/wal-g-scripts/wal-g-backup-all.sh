#!/usr/bin/env bash
# ==============================================================================
# wal-g-backup-all.sh — резервное копирование всех PostgreSQL-кластеров через WAL-G
# (неинтерактивный режим для systemd-таймера; запускать от root)
# ==============================================================================

set -uo pipefail

# ── Константы ──────────────────────────────────────────────────────────────────
readonly WALG_DIR="/etc/wal-g.d"
readonly WALG_BIN="/usr/bin/wal-g"
readonly PG_USER="postgres"
readonly RETAIN="${RETAIN:-3}"   # сколько FULL-бэкапов хранить (переопределяемо через env)

# ── Глобальный счётчик ошибок ──────────────────────────────────────────────────
errors=0

# ── Вспомогательные функции ────────────────────────────────────────────────────
log()  { echo "[$(date '+%F %T')] INFO  $*"; }
warn() { echo "[$(date '+%F %T')] WARN  $*" >&2; }
err()  { echo "[$(date '+%F %T')] ERROR $*" >&2; }

# ── Проверка окружения ─────────────────────────────────────────────────────────
check_env() {
  local fail=0

  [[ -d "${WALG_DIR}" ]] || { err "Каталог конфигов не найден: ${WALG_DIR}"; fail=1; }
  [[ -x "${WALG_BIN}" ]] || { err "WAL-G бинарник не найден / не исполняемый: ${WALG_BIN}"; fail=1; }
  command -v python3 &>/dev/null || { err "python3 не найден в PATH"; fail=1; }

  (( fail == 0 ))
}

# ── Извлечь PGDATA из JSON-конфига ────────────────────────────────────────────
get_pgdata() {
  local cfg="$1"
  python3 - "$cfg" <<'PY'
import json, sys
cfg = sys.argv[1]
try:
    with open(cfg, encoding="utf-8") as f:
        val = json.load(f).get("PGDATA", "")
    print(val)
except Exception as e:
    print(f"PARSE_ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PY
}

# ── Извлечь PORT из JSON-конфига ──────────────────────────────────────────────
get_port() {
  local cfg="$1"
  python3 - "$cfg" <<PY
import json, sys
cfg = sys.argv[1]
try:
    with open(cfg, encoding="utf-8") as f:
        val = json.load(f).get("PGPORT", "")
    print(str(val).strip())
except Exception as e:
    print(f"PARSE_ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PY
}

# ── Резервное копирование одного кластера ──────────────────────────────────────
backup_cluster() {
  local cfg="$1"
  local port="$2"
  local pgdata="$3"
  # RETAIN передаём явно — su - сбрасывает окружение
  local retain="${RETAIN}"

  local logdir="${pgdata}/log"
  local logfile="${logdir}/wal-g-backup-${port}-$(date +%F).log"

  mkdir -p "${logdir}" && chown "${PG_USER}:${PG_USER}" "${logdir}" || {
    err "Не удалось создать каталог логов: ${logdir}"
    return 1
  }

  log "Запуск резервного копирования: port=${port}, cfg=${cfg}"
  log "Лог: ${logfile}"

  # Все значения передаём через явные переменные в heredoc,
  # чтобы не зависеть от окружения login shell.
  su - "${PG_USER}" -s /bin/bash <<SHELL
set -uo pipefail

WALG_BIN="${WALG_BIN}"
CFG="${cfg}"
PGDATA="${pgdata}"
PORT="${port}"
RETAIN="${retain}"
LOGFILE="${logfile}"

backup_rc=0
delete_rc=0

{
  echo "===== \$(date '+%F %T') ===== START backup-push (delta) port=\${PORT} ====="

  "\${WALG_BIN}" backup-push --config "\${CFG}" "\${PGDATA}" \
    || backup_rc=\$?

  echo "===== \$(date '+%F %T') ===== END backup-push (delta) rc=\${backup_rc} ====="

  # ── Если delta упала — пробуем FULL ────────────────────────────────────────
  if (( backup_rc != 0 )); then
    echo "===== \$(date '+%F %T') ===== WARN delta rc=\${backup_rc}, запускаем FULL ====="
    backup_rc=0

    echo "===== \$(date '+%F %T') ===== START backup-push --full port=\${PORT} ====="

    "\${WALG_BIN}" backup-push --full --config "\${CFG}" "\${PGDATA}" \
      || backup_rc=\$?

    echo "===== \$(date '+%F %T') ===== END backup-push --full rc=\${backup_rc} ====="
  fi

  # ── delete retain — только если push прошёл успешно ───────────────────────
  if (( backup_rc == 0 )); then
    echo "===== \$(date '+%F %T') ===== START delete retain FULL \${RETAIN} ====="

    "\${WALG_BIN}" delete retain FULL "\${RETAIN}" \
      --confirm --config "\${CFG}" \
      || delete_rc=\$?

    echo "===== \$(date '+%F %T') ===== END delete rc=\${delete_rc} ====="
  else
    echo "===== \$(date '+%F %T') ===== SKIP delete: backup rc=\${backup_rc} ====="
  fi

} >> "\${LOGFILE}" 2>&1

# Возвращаем итоговый код — без (( )), чтобы не триггерить set -e при нуле
if (( backup_rc != 0 || delete_rc != 0 )); then
  exit 1
fi
exit 0
SHELL
}


# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════
main() {
  check_env || exit 1

  shopt -s nullglob
  local confs=( "${WALG_DIR}"/.walg-*.json )
  shopt -u nullglob

  if (( ${#confs[@]} == 0 )); then
    err "Конфиги не найдены: ${WALG_DIR}/.walg-*.json"
    exit 1
  fi

  log "Найдено конфигов: ${#confs[@]}"

  local cfg port pgdata
  for cfg in "${confs[@]}"; do

    # ── Порт ────────────────────────────────────────────────────────────────
    port="$(get_port "${cfg}")" || {
      err "Ошибка парсинга порта: ${cfg} — пропуск"
      (( errors++ )) || true
      continue
    }

    if [[ ! "${port}" =~ ^[0-9]+$ ]]; then
      err "PGPORT не задан или некорректен: ${cfg} — пропуск"
      (( errors++ )) || true
      continue
    fi

    # ── PGDATA ──────────────────────────────────────────────────────────────
    pgdata="$(get_pgdata "${cfg}")" || {
      err "Ошибка парсинга PGDATA: ${cfg} — пропуск"
      (( errors++ )) || true
      continue
    }

    if [[ -z "${pgdata}" ]]; then
      err "PGDATA не задан в конфиге: ${cfg} — пропуск"
      (( errors++ )) || true
      continue
    fi

    if [[ ! -d "${pgdata}" ]]; then
      err "PGDATA не существует: '${pgdata}' (cfg=${cfg}) — пропуск"
      (( errors++ )) || true
      continue
    fi

    # ── Запуск ──────────────────────────────────────────────────────────────
    backup_cluster "${cfg}" "${port}" "${pgdata}" || {
      err "Ошибка резервного копирования: port=${port}, cfg=${cfg}"
      (( errors++ )) || true
    }
  done

  if (( errors > 0 )); then
    err "Завершено с ошибками: ${errors} кластер(ов)"
    exit 1
  fi

  log "Все резервные копии успешно созданы"
  exit 0
}

main "$@"
