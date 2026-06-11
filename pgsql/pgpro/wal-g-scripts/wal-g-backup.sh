#!/bin/bash
# ==============================================================================
# wal-g-backup.sh — интерактивное создание WAL-G бэкапов
# ==============================================================================
set -euo pipefail

# ─────────────────────────────────────────────
#  Вспомогательные функции
# ─────────────────────────────────────────────

prompt_default() {
  local msg="${1:-}" default="${2:-}" val
  read -r -p "${msg} [${default}]: " val
  echo "${val:-$default}"
}

prompt_required() {
  local msg="$1" val
  while [[ -z "${val:-}" ]]; do
    read -r -p "${msg}: " val
    [[ -z "$val" ]] && echo "  Значение не может быть пустым." >&2
  done
  echo "$val"
}

# ─────────────────────────────────────────────
#  Параметры
# ─────────────────────────────────────────────

PGVER="$(prompt_default 'Введите версию PostgreSQL (PGVER)' '1c-18')"
WALG_CONFIG_DIR="/etc/wal-g.d"

# ─────────────────────────────────────────────
#  Обнаружение кластеров (по ss)
# ─────────────────────────────────────────────

FOUND_PORTS=()
if command -v ss >/dev/null 2>&1; then
  mapfile -t FOUND_PORTS < <(
    ss -tlnp 2>/dev/null \
      | grep -i postgres \
      | grep -oP ':\d+' \
      | grep -oP '\d+' \
      | sort -u
  )
fi

# ─────────────────────────────────────────────
#  Фильтрация: кластер + конфиг должны совпасть
# ─────────────────────────────────────────────

VALID_PORTS=()
declare -A PORT_DATA   # PORT_DATA[port]=pgdata

check_port() {
  local port="$1"
  local cfg="${WALG_CONFIG_DIR}/.walg-${port}.json"

  if [[ ! -f "$cfg" ]]; then
    echo "  [SKIP] Порт ${port}: конфиг ${cfg} не найден"
    return 1
  fi

  if ! pg_isready -p "$port" -U postgres -t 3 >/dev/null 2>&1; then
    echo "  [SKIP] Порт ${port}: кластер недоступен"
    return 1
  fi

  local pgdata
  pgdata="$(psql -p "$port" -U postgres -d postgres -At \
              -c "show data_directory;" 2>/dev/null || true)"

  if [[ -z "$pgdata" || ! -d "$pgdata" ]]; then
    echo "  [SKIP] Порт ${port}: не удалось определить PGDATA"
    return 1
  fi

  PORT_DATA[$port]="$pgdata"
  return 0
}

# ─────────────────────────────────────────────
#  Сканирование + единый вывод списка
# ─────────────────────────────────────────────

scan_ports() {
  local ports=("$@")
  for p in "${ports[@]}"; do
    if check_port "$p"; then
      VALID_PORTS+=("$p")
    fi
  done
}

echo ""
echo "=== Доступные кластеры ==="

if [[ ${#FOUND_PORTS[@]} -gt 0 ]]; then
  scan_ports "${FOUND_PORTS[@]}"
else
  echo "  Автообнаружение не дало результатов."
fi

# ─────────────────────────────────────────────
#  Ручной ввод если ничего не найдено
# ─────────────────────────────────────────────

if [[ ${#VALID_PORTS[@]} -eq 0 ]]; then
  echo ""
  echo "WARN: не найдено ни одного кластера с конфигом WAL-G." >&2
  MANUAL="$(prompt_required 'Укажите порты вручную через пробел (например: 5432 5433)')"
  read -r -a MANUAL_PORTS <<< "$MANUAL"
  scan_ports "${MANUAL_PORTS[@]}"

  if [[ ${#VALID_PORTS[@]} -eq 0 ]]; then
    echo "ERROR: нет доступных кластеров с валидной конфигурацией — выход." >&2
    exit 1
  fi
fi

# ── Единый нумерованный список ──
echo ""
for i in "${!VALID_PORTS[@]}"; do
  p="${VALID_PORTS[$i]}"
  cfg="${WALG_CONFIG_DIR}/.walg-${p}.json"
  echo "  $((i+1)). [ OK ] Порт ${p}  |  PGDATA=${PORT_DATA[$p]}, конфиг=${cfg}"
done
echo "  0. Выход"
echo ""

# ─────────────────────────────────────────────
#  Выбор портов для бэкапа
# ─────────────────────────────────────────────

SEL="$(prompt_default "Укажите номера через пробел, 'all' для всех или '0' для выхода" 'all')"

if [[ "$SEL" == "0" || "${SEL,,}" == "q" || "${SEL,,}" == "exit" ]]; then
  echo "Выход из скрипта."
  exit 0
fi

SELECTED_PORTS=()
if [[ "${SEL,,}" == "all" ]]; then
  SELECTED_PORTS=("${VALID_PORTS[@]}")
else
  read -r -a INPUT_NUMS <<< "$SEL"
  for num in "${INPUT_NUMS[@]}"; do
    if ! [[ "$num" =~ ^[0-9]+$ ]]; then
      echo "  [WARN] '${num}' — не число, пропускаем." >&2
      continue
    fi
    idx=$(( num - 1 ))
    if [[ $idx -lt 0 || $idx -ge ${#VALID_PORTS[@]} ]]; then
      echo "  [WARN] Номер ${num} вне диапазона — пропускаем." >&2
      continue
    fi
    SELECTED_PORTS+=("${VALID_PORTS[$idx]}")
  done
fi

if [[ ${#SELECTED_PORTS[@]} -eq 0 ]]; then
  echo "ERROR: нет кластера для бэкапа — выход." >&2
  exit 1
fi

# ─────────────────────────────────────────────
#  Запрос типа бэкапа
# ─────────────────────────────────────────────

echo ""
FORCE_FULL_INPUT="$(prompt_default 'Запустить FULL-бэкап для всех выбранных кластеров? (y/N)' 'N')"

FORCE_FULL=false
if [[ "${FORCE_FULL_INPUT,,}" == "y" ]]; then
  FORCE_FULL=true
  echo "  Режим: FULL-бэкап."
else
  echo "  Режим: Delta (при отсутствии базового — автоматически FULL)."
fi

# ─────────────────────────────────────────────
#  Запуск бэкапов
# ─────────────────────────────────────────────

echo ""
echo "=== Запуск бэкапов ==="

ERRORS=0
for PGPORT in "${SELECTED_PORTS[@]}"; do
  PGDATA="${PORT_DATA[$PGPORT]}"
  WALG_CONFIG_FILE="${WALG_CONFIG_DIR}/.walg-${PGPORT}.json"

  echo ""
  echo ">>> Бэкап: порт=${PGPORT}  PGDATA=${PGDATA}"
  echo "    Конфиг: ${WALG_CONFIG_FILE}"

  if [[ "$FORCE_FULL" == true ]]; then
    # ── Принудительный FULL ──
    echo "    Запуск FULL-бэкапа..."
    if su - postgres -c \
         "/usr/bin/wal-g backup-push --full --config '${WALG_CONFIG_FILE}' '${PGDATA}'"; then
      echo "    [OK] FULL бэкап ${PGPORT} завершён успешно."
    else
      echo "    [FAIL] FULL бэкап ${PGPORT} завершился с ошибкой!" >&2
      (( ERRORS++ )) || true
    fi
  else
    # ── Delta → при ошибке FULL ──
    echo "    Попытка delta-бэкапа..."
    if ! su - postgres -c \
         "/usr/bin/wal-g backup-push --config '${WALG_CONFIG_FILE}' '${PGDATA}'" 2>&1; then
      echo "    Delta не удалась — пробуем FULL бэкап..." >&2
      if su - postgres -c \
           "/usr/bin/wal-g backup-push --full --config '${WALG_CONFIG_FILE}' '${PGDATA}'"; then
        echo "    [OK] FULL бэкап ${PGPORT} завершён успешно."
      else
        echo "    [FAIL] FULL бэкап ${PGPORT} завершился с ошибкой!" >&2
        (( ERRORS++ )) || true
      fi
    else
      echo "    [OK] Delta бэкап ${PGPORT} завершён успешно."
    fi
  fi
done

# ─────────────────────────────────────────────
#  Итог
# ─────────────────────────────────────────────

echo ""
echo "=== Итог ==="
echo "  Всего бэкапов: ${#SELECTED_PORTS[@]}"
echo "  Ошибок:        ${ERRORS}"

[[ $ERRORS -eq 0 ]] && exit 0 || exit 1
