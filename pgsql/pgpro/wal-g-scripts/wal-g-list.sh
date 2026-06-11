#!/bin/bash
# ==============================================================================
# wal-g-list.sh — интерактивный вывод списка WAL-G бэкапов
# ==============================================================================
set -euo pipefail

# ── Константы ────────────────────────────────────────────────────────────────
WALG_DIR="/etc/wal-g.d"
WALG_BIN="${WALG_BIN:-/usr/bin/wal-g}"

# ── Цвета ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Проверка зависимостей ────────────────────────────────────────────────────
if [[ ! -x "$WALG_BIN" ]]; then
  echo "ERROR: wal-g not found or not executable: $WALG_BIN" >&2
  exit 1
fi

# ── Проверка директории ──────────────────────────────────────────────────────
if [[ ! -d "$WALG_DIR" ]]; then
  echo "ERROR: directory not found: $WALG_DIR" >&2
  exit 1
fi

# ── Сбор конфигов ────────────────────────────────────────────────────────────
mapfile -t CFGS < <(find "$WALG_DIR" -maxdepth 1 -type f -name ".walg-*.json" | sort)

if [[ ${#CFGS[@]} -eq 0 ]]; then
  echo "ERROR: no wal-g configs found in $WALG_DIR (expected .walg-*.json)" >&2
  exit 2
fi

# ── Парсинг флагов ───────────────────────────────────────────────────────────
FULL_ONLY=false

print_usage() {
  echo "Usage: $0 [--full|-f] [PORT|all]"
  echo
  echo "  --full, -f   показывать только FULL-бэкапы (без дифференциальных)"
  echo "  PORT         номер порта PostgreSQL (1–65535)"
  echo "  all          обработать все найденные конфиги"
}

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --full|-f)
      FULL_ONLY=true
      shift
      ;;
    --help|-h)
      print_usage
      exit 0
      ;;
    -*)
      echo "ERROR: unknown option: $1" >&2
      print_usage >&2
      exit 1
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

# ── Извлечь порт из имени конфига ────────────────────────────────────────────
extract_port() {
  local cfg="$1"
  local base
  base="$(basename "$cfg")"
  base="${base#.walg-}"
  echo "${base%.json}"
}

# ── Вывод меню доступных кластеров ───────────────────────────────────────────
print_menu() {
  echo
  echo -e "${BOLD}=== Доступные кластеры ===${RESET}"
  echo

  local i=1
  for cfg in "${CFGS[@]}"; do
    local port
    port="$(extract_port "$cfg")"

    if [[ -f "$cfg" && -r "$cfg" ]]; then
      echo -e "   ${BOLD}${i}.${RESET} [ ${GREEN}OK${RESET} ] Порт ${port}"
    else
      echo -e "   ${BOLD}${i}.${RESET} [ ${RED}FAIL${RESET} ] Порт ${port} — конфиг недоступен"
    fi

    (( i++ ))
  done

  echo
  echo -e "   ${BOLD}${i}.${RESET} Все кластеры"
  echo -e "   ${BOLD}0.${RESET} Выход"
  echo
}

# ── Функция: запуск backup-list ──────────────────────────────────────────────
run_backup_list() {
  local cfg="$1"
  local port
  port="$(extract_port "$cfg")"

  echo
  echo -e "${BOLD}=== WAL-G backup-list · Порт ${port} ===${RESET}"
  echo

  if [[ "$FULL_ONLY" == "true" ]]; then
    "$WALG_BIN" backup-list --pretty --config "$cfg" | grep -v "_D_"
  else
    "$WALG_BIN" backup-list --pretty --config "$cfg"
  fi
}

# ── Режим: аргумент передан из CLI ───────────────────────────────────────────
if [[ $# -ge 1 ]]; then
  INPUT="$1"

  if [[ "${INPUT,,}" == "all" ]]; then
    errors=0
    for cfg in "${CFGS[@]}"; do
      run_backup_list "$cfg" || (( errors++ )) || true
    done
    if (( errors > 0 )); then
      echo -e "${YELLOW}WARN: $errors config(s) failed${RESET}" >&2
      exit 5
    fi
    exit 0
  fi

  if [[ ! "$INPUT" =~ ^[1-9][0-9]{0,4}$ ]] || (( INPUT > 65535 )); then
    echo "ERROR: invalid port: '$INPUT' (expected 1–65535, no leading zeros)" >&2
    exit 3
  fi

  WALG_CONFIG_FILE="$WALG_DIR/.walg-${INPUT}.json"
  if [[ ! -f "$WALG_CONFIG_FILE" ]]; then
    echo "ERROR: config not found for port $INPUT: $WALG_CONFIG_FILE" >&2
    exit 4
  fi

  run_backup_list "$WALG_CONFIG_FILE"
  exit 0
fi

# ── Интерактивный режим ───────────────────────────────────────────────────────
if [[ ! -t 0 ]]; then
  echo "ERROR: no TTY and no argument provided. Usage: $0 [--full|-f] [PORT|all]" >&2
  exit 1
fi

TOTAL="${#CFGS[@]}"
ALL_IDX=$(( TOTAL + 1 ))

# ── 1. Показываем меню ───────────────────────────────────────────────────────
print_menu

# ── 2. Выбор кластера ────────────────────────────────────────────────────────
SELECTED_CFGS=()

while true; do
  read -r -p "Выберите номер [0–${ALL_IDX}]: " CHOICE

  if [[ "$CHOICE" == "0" ]]; then
    echo "Выход."
    exit 0
  fi

  if [[ ! "$CHOICE" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Некорректный ввод. Введите число от 0 до ${ALL_IDX}.${RESET}" >&2
    continue
  fi

  if (( CHOICE == ALL_IDX )); then
    SELECTED_CFGS=( "${CFGS[@]}" )
    break
  fi

  if (( CHOICE >= 1 && CHOICE <= TOTAL )); then
    SELECTED_CFGS=( "${CFGS[(( CHOICE - 1 ))]}" )
    break
  fi

  echo -e "${RED}Номер вне диапазона. Введите от 0 до ${ALL_IDX}.${RESET}" >&2
done

# ── 3. Вопрос про FULL-only (только если флаг не задан через CLI) ────────────
if [[ "$FULL_ONLY" == "false" ]]; then
  echo
  read -r -p "Показывать только FULL-бэкапы? [y/N]: " FULL_ANSWER
  if [[ "${FULL_ANSWER,,}" =~ ^y(es)?$ ]]; then
    FULL_ONLY=true
  fi
fi

# ── 4. Вывод бэкапов ─────────────────────────────────────────────────────────
errors=0
for cfg in "${SELECTED_CFGS[@]}"; do
  run_backup_list "$cfg" || (( errors++ )) || true
done

if (( errors > 0 )); then
  echo -e "${YELLOW}WARN: $errors config(s) failed${RESET}" >&2
  exit 5
fi

exit 0
