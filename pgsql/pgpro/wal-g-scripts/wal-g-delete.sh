#!/bin/bash
# ==============================================================================
# wal-g-delete.sh — интерактивное удаление WAL-G бэкапов
# ==============================================================================

set -uo pipefail

# ── Константы ──────────────────────────────────────────────────────────────────
readonly WALG_DIR="/etc/wal-g.d"
readonly WALG_BIN="/usr/bin/wal-g"

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

  local backup_list
  backup_list="$("${WALG_BIN}" backup-list --pretty --config "${cfg}" 2>&1)"
  local rc=$?

  if (( rc != 0 )); then
    err "Не удалось получить список бэкапов"
    echo "${backup_list}" >&2
    return 1
  fi

  if [[ -z "${backup_list}" ]]; then
    echo "  (бэкапы не найдены)"
    separator
    echo
    return 0
  fi

  echo "${backup_list}" | awk '
    NR==1 { print "  " $0; next }
    /FULL/ { print "  \033[1;32m" $0 "\033[0m"; next }
           { print "  \033[0;33m" $0 "\033[0m" }
  '
  separator
  echo

  # Подсчёт FULL-бэкапов: всё что не содержит _D_ (исключая заголовок)
  local full_count
  full_count="$("${WALG_BIN}" backup-list --pretty --config "${cfg}" \
    | grep -v "_D_" \
    | grep -c "base_")"

  echo "  Всего FULL-бэкапов: ${full_count}"
  echo
  
  local full_backup_list
  full_backup_list="$("${WALG_BIN}" backup-list --pretty --config "${cfg}" | grep -v "_D_")"
  
  echo "${full_backup_list}" | awk '
    NR==1 { print "  " $0; next }
    /FULL/ { print "  \033[1;32m" $0 "\033[0m"; next }
           { print "  \033[0;33m" $0 "\033[0m" }
  '
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

  # ── Запрашиваем количество FULL-копий для хранения ───────────────────────
  local retain
  while true; do
    read -rp "Сколько FULL-бэкапов оставить? [введите число]: " retain
    [[ "${retain}" =~ ^[1-9][0-9]*$ ]] && break
    echo "  ✗ Введите целое число больше 0."
  done

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
