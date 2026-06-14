#!/bin/bash
# ==============================================================================
# wal-g-list.sh — интерактивный вывод списка WAL-G бэкапов
# ==============================================================================
set -euo pipefail

# ── Константы ────────────────────────────────────────────────────────────────
WALG_DIR="/etc/wal-g.d"
WALG_BIN="${WALG_BIN:-/usr/bin/wal-g}"

# ── Цвета (только в интерактивный TTY и при отсутствии NO_COLOR) ──────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED='' GREEN='' YELLOW='' CYAN='' BOLD='' RESET=''
fi

# ── Постраничный вывод ───────────────────────────────────────────────────────
# Прогоняем вывод через пейджер, только когда он не влезает на экран.
#   less -R  — сохранить ANSI-цвета
#        -F  — не запускать пейджер, если вывод помещается в один экран
#        -X  — не очищать экран при выходе (вывод остаётся в истории терминала)
# Пейджер задействуется лишь в интерактивном TTY; иначе (пайп/файл) — обычный cat,
# чтобы не ломать скриптовое использование. Переопределяется через $PAGER.
page_output() {
  if [[ -t 1 ]]; then
    if [[ -n "${PAGER:-}" ]]; then
      eval "$PAGER"
    elif command -v less >/dev/null 2>&1; then
      less -RFX
    else
      cat
    fi
  else
    cat
  fi
}

# Временный файл для накопления вывода перед пейджером (чистим на выходе).
TMPFILE=""
cleanup() { [[ -n "$TMPFILE" ]] && rm -f "$TMPFILE"; }
trap cleanup EXIT

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
  echo
  echo "  NO_COLOR=1   отключить ANSI-цвета принудительно"
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

    i=$(( i + 1 ))
  done

  echo
  echo -e "   ${BOLD}${i}.${RESET} Все кластеры"
  echo -e "   ${BOLD}0.${RESET} Выход"
  echo
}

# ── Функция: запуск backup-list для одного конфига ───────────────────────────
# Возвращает 0 при успехе (включая «нет бэкапов»), 1 при сбое wal-g/конфига.
run_backup_list() {
  local cfg="$1"
  local port
  port="$(extract_port "$cfg")"

  echo
  echo -e "${BOLD}=== WAL-G backup-list · Порт ${port} ===${RESET}"
  echo

  if [[ ! -r "$cfg" ]]; then
    echo -e "${RED}ERROR: конфиг недоступен для чтения: ${cfg}${RESET}" >&2
    return 1
  fi

  # Захватываем вывод целиком, чтобы отделить сбой wal-g от пустого результата
  # (иначе grep-фильтр без совпадений ложно трактуется как ошибка под pipefail).
  local out rc
  out="$("$WALG_BIN" backup-list --pretty --config "$cfg" 2>&1)"
  rc=$?

  if (( rc != 0 )); then
    echo -e "${RED}ERROR: backup-list завершился с кодом ${rc}${RESET}" >&2
    [[ -n "$out" ]] && echo "$out" >&2
    return 1
  fi

  # Подсчёт: строки бэкапов содержат 'base_', delta — дополнительно '_D_'.
  local total delta full
  total="$(printf '%s\n' "$out" | grep -c 'base_' || true)"
  delta="$(printf '%s\n' "$out" | grep -c '_D_'  || true)"
  full=$(( total - delta ))

  if (( total == 0 )); then
    echo "  (бэкапы не найдены)"
    echo
    return 0
  fi

  # Вывод таблицы — с фильтром FULL-only или полностью.
  if [[ "$FULL_ONLY" == "true" ]]; then
    if (( full == 0 )); then
      echo "  (FULL-бэкапов нет; всего delta: ${delta})"
    else
      printf '%s\n' "$out" | grep -v '_D_' || true
    fi
  else
    printf '%s\n' "$out"
  fi

  # Сводка: счётчики + самый свежий бэкап (последняя строка таблицы).
  local latest_line latest_name latest_date summary
  latest_line="$(printf '%s\n' "$out" | grep 'base_' | tail -n1 || true)"
  latest_name="$(printf '%s\n' "$latest_line" | grep -oE 'base_[0-9A-Za-z_]+' | head -n1 || true)"
  latest_date="$(printf '%s\n' "$latest_line" \
    | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2})?' | head -n1 || true)"

  summary="FULL: ${full} · delta: ${delta} · всего: ${total}"
  [[ -n "$latest_name" ]] && summary+=" · последний: ${latest_name}"
  [[ -n "$latest_date" ]] && summary+=" (${latest_date})"

  echo
  echo -e "${CYAN}  Сводка: ${summary}${RESET}"
  return 0
}

# ── Обработка набора конфигов с постраничным выводом ─────────────────────────
# Накапливаем stdout всех run_backup_list во временный файл и отдаём пейджеру,
# который сам решает, нужна ли постраничность. Ошибки (stderr) идут напрямую в
# терминал, не попадая в пейджер, чтобы сохранить потоковую семантику.
# Возвращает 0 при успехе, 5 если хотя бы один конфиг завершился сбоем.
run_selected() {
  local errors=0 cfg
  TMPFILE="$(mktemp "${TMPDIR:-/tmp}/walg-list.XXXXXX")" || {
    echo "ERROR: не удалось создать временный файл" >&2
    return 1
  }

  for cfg in "$@"; do
    run_backup_list "$cfg" >>"$TMPFILE" || (( errors++ )) || true
  done

  page_output <"$TMPFILE"

  if (( errors > 0 )); then
    echo -e "${YELLOW}WARN: $errors config(s) failed${RESET}" >&2
    return 5
  fi
  return 0
}

# ── Режим: аргумент передан из CLI ───────────────────────────────────────────
if [[ $# -ge 1 ]]; then
  INPUT="$1"

  if [[ "${INPUT,,}" == "all" ]]; then
    run_selected "${CFGS[@]}" || exit $?
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

  run_selected "$WALG_CONFIG_FILE" || exit 5
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
    SELECTED_CFGS=( "${CFGS[CHOICE-1]}" )
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
run_selected "${SELECTED_CFGS[@]}" || exit 5

exit 0
