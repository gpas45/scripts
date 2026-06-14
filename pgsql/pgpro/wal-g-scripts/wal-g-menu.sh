#!/bin/bash
# ==============================================================================
# wal-g-menu.sh — единая интерактивная оболочка для набора WAL-G-скриптов
# ==============================================================================
# Запускает соседние скрипты (cfg/list/backup/backup-all/delete/restore) из
# одного меню. Скрипты ищутся рядом с этим файлом, поэтому оболочку можно
# вызывать из любого каталога. Запускать от root (большинство операций требует
# прав root и переключения на пользователя postgres).
# ==============================================================================

# Без -e: сбой дочернего скрипта не должен ронять меню — возвращаемся в него.
set -uo pipefail

# ── Каталог набора (рядом с этим скриптом) ───────────────────────────────────
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ── Цвета (только в интерактивный TTY и при отсутствии NO_COLOR) ──────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
fi

log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_section() { echo -e "\n${CYAN}${BOLD}>>> $* ${NC}"; }

# Прерывание (Ctrl-C) внутри дочернего скрипта не должно завершать меню.
trap 'echo; log_warn "Прервано пользователем."' INT

# ── Описание пунктов меню (данные, а не код) ─────────────────────────────────
MENU_KEYS=(1 2 3 4 5 6)
declare -A MENU_LABEL MENU_SCRIPT MENU_DESC

MENU_LABEL[1]="Настройка WAL-G"
MENU_SCRIPT[1]="wal-g-cfg.sh"
MENU_DESC[1]="создать/обновить конфиги и параметры архивации PostgreSQL"

MENU_LABEL[2]="Список бэкапов"
MENU_SCRIPT[2]="wal-g-list.sh"
MENU_DESC[2]="показать доступные бэкапы по кластерам"

MENU_LABEL[3]="Создать бэкап"
MENU_SCRIPT[3]="wal-g-backup.sh"
MENU_DESC[3]="интерактивный delta/FULL-бэкап выбранных кластеров"

MENU_LABEL[4]="Бэкап всех кластеров"
MENU_SCRIPT[4]="wal-g-backup-all.sh"
MENU_DESC[4]="неинтерактивный прогон (как в systemd-таймере) + retain"

MENU_LABEL[5]="Удалить бэкапы"
MENU_SCRIPT[5]="wal-g-delete.sh"
MENU_DESC[5]="удаление старых бэкапов (retain FULL N)"

MENU_LABEL[6]="Восстановление"
MENU_SCRIPT[6]="wal-g-restore.sh"
MENU_DESC[6]="восстановление кластера из бэкапа (в т.ч. PITR)"

# ── Проверки окружения ───────────────────────────────────────────────────────
if [[ ! -t 0 ]]; then
  log_error "Нужен интерактивный терминал (stdin не является TTY)."
  exit 1
fi

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  log_warn "Оболочка запущена не от root — большинство операций потребует прав root."
fi

# ── Вывод меню ───────────────────────────────────────────────────────────────
print_menu() {
  echo
  echo -e "${BOLD}============================================================${NC}"
  echo -e "${BOLD}             WAL-G — панель управления${NC}"
  echo -e "${BOLD}============================================================${NC}"
  echo -e "  Каталог скриптов: ${CYAN}${SCRIPT_DIR}${NC}"
  echo
  local k script_path mark
  for k in "${MENU_KEYS[@]}"; do
    script_path="${SCRIPT_DIR}/${MENU_SCRIPT[$k]}"
    if [[ -f "$script_path" ]]; then
      mark="${GREEN}●${NC}"
    else
      mark="${RED}✗${NC}"
    fi
    printf "  ${BOLD}%s.${NC} %b %-24s — %s\n" \
      "$k" "$mark" "${MENU_LABEL[$k]}" "${MENU_DESC[$k]}"
  done
  echo
  echo -e "  ${BOLD}0.${NC} Выход"
  echo
}

# ── Запуск выбранного скрипта ────────────────────────────────────────────────
run_script() {
  local script="$1"
  local path="${SCRIPT_DIR}/${script}"

  if [[ ! -f "$path" ]]; then
    log_error "Скрипт не найден: ${path}"
    return 1
  fi

  log_section "Запуск: ${script}"
  # Запускаем через интерпретатор, чтобы не зависеть от бита исполнения.
  bash "$path"
  local rc=$?

  echo
  if (( rc == 0 )); then
    log_info "«${script}» завершился успешно (rc=0)."
  else
    log_warn "«${script}» завершился с кодом ${rc}."
  fi
  return "$rc"
}

# ── Пауза перед возвратом в меню ─────────────────────────────────────────────
pause() {
  echo
  read -rsp "Нажмите Enter для возврата в меню..." _ || true
  echo
}

# ── Главный цикл ─────────────────────────────────────────────────────────────
while true; do
  print_menu
  read -rp "Выберите пункт [0-${MENU_KEYS[-1]}]: " CHOICE || { echo; exit 0; }

  case "$CHOICE" in
    0|q|Q|exit)
      echo "Выход."
      exit 0
      ;;
    [1-9]*)
      if [[ -n "${MENU_SCRIPT[$CHOICE]:-}" ]]; then
        run_script "${MENU_SCRIPT[$CHOICE]}" || true
        pause
      else
        log_warn "Нет такого пункта: ${CHOICE}"
      fi
      ;;
    *)
      log_warn "Некорректный ввод: '${CHOICE}'. Введите число из меню."
      ;;
  esac
done
