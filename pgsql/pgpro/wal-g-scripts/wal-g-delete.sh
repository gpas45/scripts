#!/bin/bash
# ==============================================================================
# wal-g-delete.sh — интерактивное удаление WAL-G бэкапов
# ==============================================================================

set -uo pipefail

# ── Константы ──────────────────────────────────────────────────────────────────
readonly WALG_DIR="/etc/wal-g.d"
readonly WALG_BIN="/usr/bin/wal-g"

# ── Цвета (только в интерактивный TTY и при отсутствии NO_COLOR) ────────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_GREEN='\033[1;32m'
  C_YELLOW='\033[0;33m'
  C_RESET='\033[0m'
else
  C_GREEN='' C_YELLOW='' C_RESET=''
fi

# Кол-во FULL-бэкапов из последнего show_backups (для проверки retain в main).
LAST_FULL_COUNT=0

# ── Вспомогательные функции ────────────────────────────────────────────────────
log()  { echo "[$(date '+%F %T')] INFO  $*"; }
err()  { echo "[$(date '+%F %T')] ERROR $*" >&2; }

separator() { echo "════════════════════════════════════════════════════════════"; }

# ── Извлечь PGPORT из JSON-конфига ────────────────────────────────────────────
get_port() {
  local cfg="$1"
  python3 - "$cfg" <<'PY'
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

# ── Проверка окружения ─────────────────────────────────────────────────────────
check_env() {
  local fail=0
  [[ -d "${WALG_DIR}" ]] || { err "Каталог конфигов не найден: ${WALG_DIR}"; fail=1; }
  [[ -x "${WALG_BIN}" ]] || { err "WAL-G не найден / не исполняемый: ${WALG_BIN}"; fail=1; }
  command -v python3 &>/dev/null || { err "python3 не найден в PATH"; fail=1; }
  (( fail == 0 ))
}

# ── Вывод списка бэкапов ───────────────────────────────────────────────────────
show_backups() {
  local cfg="$1"
  echo
  separator
  echo "  Список доступных бэкапов:"
  separator

  LAST_FULL_COUNT=0

  # Запрашиваем список один раз; stderr отделяем, чтобы INFO-логи wal-g
  # не попадали в таблицу, а при сбое — показать причину.
  local out rc errfile
  errfile="$(mktemp)"
  out="$("${WALG_BIN}" backup-list --pretty --config "${cfg}" 2>"${errfile}")"
  rc=$?

  if (( rc != 0 )); then
    err "Не удалось получить список бэкапов (rc=${rc})"
    [[ -s "${errfile}" ]] && cat "${errfile}" >&2
    rm -f "${errfile}"
    return 1
  fi
  rm -f "${errfile}"

  # Строки данных содержат 'base_'; delta-копии дополнительно — '_D_'.
  local total delta full
  total="$(printf '%s\n' "${out}" | grep -c 'base_')" || true
  delta="$(printf '%s\n' "${out}" | grep -c '_D_')"  || true
  full=$(( total - delta ))
  LAST_FULL_COUNT=${full}

  if (( total == 0 )); then
    echo "  (бэкапы не найдены)"
    separator
    echo
    return 0
  fi

  # Таблица: FULL — зелёным, delta (_D_) — жёлтым, заголовок без цвета.
  printf '%s\n' "${out}" | awk -v g="${C_GREEN}" -v y="${C_YELLOW}" -v r="${C_RESET}" '
    NR==1 { print "  " $0; next }
    /_D_/ { print "  " y $0 r; next }
          { print "  " g $0 r }
  '
  separator
  echo
  echo "  Итого:  FULL: ${full}  ·  delta: ${delta}  ·  всего: ${total}"
  echo
  return 0
}



# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════
main() {
  check_env || exit 1

  # ── Сканируем конфиги ────────────────────────────────────────────────────
  shopt -s nullglob
  local cfg_files=( "${WALG_DIR}"/.walg-*.json )
  shopt -u nullglob

  if (( ${#cfg_files[@]} == 0 )); then
    err "Конфиги не найдены: ${WALG_DIR}/.walg-*.json"
    exit 1
  fi

  # ── Собираем список портов ───────────────────────────────────────────────
  declare -A port_to_cfg
  local port

  for cfg in "${cfg_files[@]}"; do
    port="$(get_port "${cfg}" 2>/dev/null)" || continue
    [[ "${port}" =~ ^[0-9]+$ ]] || continue
    port_to_cfg["${port}"]="${cfg}"
  done

  if (( ${#port_to_cfg[@]} == 0 )); then
    err "Не найдено ни одного корректного конфига с PGPORT"
    exit 1
  fi

  # ── Выводим список портов ────────────────────────────────────────────────
  echo
  separator
  echo "  Доступные кластеры PostgreSQL (WAL-G конфиги)"
  separator

  local sorted_ports=()
  mapfile -t sorted_ports < <(printf '%s\n' "${!port_to_cfg[@]}" | sort -n)

  local i=1
  declare -A idx_to_port
  for port in "${sorted_ports[@]}"; do
    printf "  [%d] порт %-6s  →  %s\n" "$i" "${port}" "${port_to_cfg[${port}]}"
    idx_to_port[$i]="${port}"
    (( i++ ))
  done
  separator
  echo

  # ── Запрашиваем выбор порта ──────────────────────────────────────────────
  local choice
  while true; do
    read -rp "Введите номер кластера (1-$(( i-1 ))): " choice
    [[ "${choice}" =~ ^[0-9]+$ ]] \
      && (( choice >= 1 && choice <= i-1 )) \
      && break
    echo "  ✗ Некорректный выбор, попробуйте снова."
  done

  local selected_port="${idx_to_port[${choice}]}"
  local selected_cfg="${port_to_cfg[${selected_port}]}"

  log "Выбран кластер: порт=${selected_port}, конфиг=${selected_cfg}"

  # ── Показываем список бэкапов ────────────────────────────────────────────
  show_backups "${selected_cfg}" || exit 1

  # ── Если FULL-бэкапов нет — удалять нечего ────────────────────────────────
  if (( LAST_FULL_COUNT == 0 )); then
    log "FULL-бэкапов нет — удалять нечего."
    exit 0
  fi

  # ── Запрашиваем количество FULL-копий для хранения ───────────────────────
  local retain
  while true; do
    read -rp "Сколько FULL-бэкапов оставить? [введите число]: " retain
    [[ "${retain}" =~ ^[1-9][0-9]*$ ]] && break
    echo "  ✗ Введите целое число больше 0."
  done

  if (( retain >= LAST_FULL_COUNT )); then
    echo
    echo "  ⚠ FULL-бэкапов всего ${LAST_FULL_COUNT}; при retain=${retain} удалять нечего."
  fi

  # ── Итоговая сводка ──────────────────────────────────────────────────────
  echo
  separator
  echo "  Параметры удаления:"
  echo "  Кластер        : порт ${selected_port}"
  echo "  Конфиг         : ${selected_cfg}"
  echo "  Оставить FULL  : ${retain}"
  echo "  Команда        : wal-g delete retain FULL ${retain} --confirm"
  separator
  echo

  # ── Запрашиваем подтверждение ────────────────────────────────────────────
  local confirm
  read -rp "Для подтверждения введите YES (заглавными буквами): " confirm

  if [[ "${confirm}" != "YES" ]]; then
    echo
    log "Операция отменена пользователем."
    exit 0
  fi

  # ── Выполняем удаление ───────────────────────────────────────────────────
  echo
  log "Запуск удаления: port=${selected_port}, retain FULL ${retain}"
  echo

  "${WALG_BIN}" delete retain FULL "${retain}" --confirm --config "${selected_cfg}"
  local rc=$?

  echo
  if (( rc == 0 )); then
    log "Удаление завершено успешно (port=${selected_port})"
  else
    err "Удаление завершилось с ошибкой rc=${rc} (port=${selected_port})"
    exit "${rc}"
  fi
}

main "$@"
