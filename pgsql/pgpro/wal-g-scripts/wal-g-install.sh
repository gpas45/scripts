#!/bin/bash
# ==============================================================================
# wal-g-install.sh — установка набора WAL-G-скриптов и systemd-задания
# ==============================================================================
# Команды:
#   wal-g-install.sh [install]        полная установка: скрипты + systemd-юниты
#   wal-g-install.sh units            только установить/обновить systemd-юниты
#   wal-g-install.sh uninstall-units  удалить systemd-юниты (disable + rm)
#   wal-g-install.sh uninstall        удалить юниты и установленные скрипты
#
# Версия PostgreSQL (PGVER) определяется автоматически (systemd-юниты
# postgrespro-* и каталоги /var/lib/pgpro/<ver>/), иначе запрашивается.
# Запускать от root.
# ==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ── Значения по умолчанию ────────────────────────────────────────────────────
DEFAULT_INSTALL_DIR="/var/lib/pgpro/_backup/scripts"
DEFAULT_ONCALENDAR="*-*-* 01:15:00"
SYSTEMD_DIR="/etc/systemd/system"
UNIT_SERVICE="backup-pgsql.service"
UNIT_TIMER="backup-pgsql.timer"
BIN_SYMLINK="/usr/local/bin/wal-g-menu"

# Заполняются в do_install / units
INSTALL_DIR=""
ONCALENDAR=""

# ── Цвета ────────────────────────────────────────────────────────────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
fi
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_sect()  { echo -e "\n${CYAN}${BOLD}>>> $* ${NC}"; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    log_error "Требуются права root."
    exit 1
  fi
}

# ── Определение версий PostgreSQL ────────────────────────────────────────────
# Печатает уникальные версии (по одной в строке), отсортированные.
detect_pgver() {
  local -A seen=()
  local v b d unit

  if command -v systemctl >/dev/null 2>&1; then
    while read -r unit _; do
      [[ "$unit" =~ ^postgrespro-(.+)\.service$ ]] || continue
      v="${BASH_REMATCH[1]}"
      v="${v%@}"                       # postgrespro-1c-18@.service → 1c-18
      [[ -n "$v" ]] && seen["$v"]=1
    done < <(systemctl list-unit-files 'postgrespro-*.service' --no-legend 2>/dev/null)
  fi

  shopt -s nullglob
  for d in /var/lib/pgpro/*/; do
    b="$(basename "${d%/}")"
    [[ "$b" == "_backup" ]] && continue   # служебный каталог
    seen["$b"]=1
  done
  shopt -u nullglob

  (( ${#seen[@]} > 0 )) && printf '%s\n' "${!seen[@]}" | sort
}

# Возвращает выбранную версию на stdout; диалоги/сообщения — на stderr,
# поэтому безопасно вызывать как PGVER="$(resolve_pgver)".
resolve_pgver() {
  local -a cands=()
  mapfile -t cands < <(detect_pgver)

  local def=""
  (( ${#cands[@]} >= 1 )) && def="${cands[0]}"

  if (( ${#cands[@]} > 1 )); then
    {
      echo "Обнаружено несколько версий PostgreSQL:"
      local i=1 c
      for c in "${cands[@]}"; do echo "  $i) $c"; ((i++)); done
    } >&2
    if [[ -t 0 ]]; then
      local sel
      read -rp "Выберите номер версии [1]: " sel || sel=""
      sel="${sel:-1}"
      if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#cands[@]} )); then
        def="${cands[$((sel-1))]}"
      fi
    fi
  elif (( ${#cands[@]} == 1 )); then
    echo "INFO: обнаружена версия PostgreSQL: ${def}" >&2
  else
    echo "WARN: версия PostgreSQL не обнаружена автоматически." >&2
  fi

  # Переменная окружения PGVER имеет приоритет как умолчание.
  def="${PGVER:-${def:-1c-18}}"

  if [[ -t 0 ]]; then
    local ans
    read -rp "Версия PostgreSQL (PGVER) [${def}]: " ans || ans=""
    def="${ans:-$def}"
  fi

  printf '%s\n' "$def"
}

# ── Текущие значения из уже установленных юнитов (для refresh) ───────────────
current_install_dir() {
  local f="${SYSTEMD_DIR}/${UNIT_SERVICE}" line
  [[ -f "$f" ]] || return 1
  line="$(grep -m1 '^ExecStart=' "$f" 2>/dev/null)" || return 1
  line="${line#ExecStart=}"
  [[ -n "$line" ]] || return 1
  dirname "$line"
}
current_oncalendar() {
  local f="${SYSTEMD_DIR}/${UNIT_TIMER}" line
  [[ -f "$f" ]] || return 1
  line="$(grep -m1 '^OnCalendar=' "$f" 2>/dev/null)" || return 1
  echo "${line#OnCalendar=}"
}

# ── Установка скриптов ───────────────────────────────────────────────────────
install_scripts() {
  install -d -m 755 "$INSTALL_DIR" || { log_error "Не удалось создать ${INSTALL_DIR}"; return 1; }

  local src_real dst_real
  src_real="$(cd "$SCRIPT_DIR" && pwd -P)"
  dst_real="$(cd "$INSTALL_DIR" && pwd -P)"
  if [[ "$src_real" == "$dst_real" ]]; then
    log_warn "Каталог установки совпадает с каталогом исходников — копирование скриптов пропущено."
    return 0
  fi

  local -a files=()
  shopt -s nullglob
  files=( "$SCRIPT_DIR"/wal-g-*.sh )
  shopt -u nullglob
  if (( ${#files[@]} == 0 )); then
    log_error "В каталоге ${SCRIPT_DIR} не найдено ни одного wal-g-*.sh"
    return 1
  fi

  local f
  for f in "${files[@]}"; do
    install -m 755 "$f" "$INSTALL_DIR/"
  done
  log_info "Установлено скриптов: ${#files[@]} → ${INSTALL_DIR}"
}

# ── Генерация и установка systemd-юнитов ─────────────────────────────────────
install_units() {
  local pgver="$1"
  : "${INSTALL_DIR:=$DEFAULT_INSTALL_DIR}"
  : "${ONCALENDAR:=$DEFAULT_ONCALENDAR}"

  cat > "${SYSTEMD_DIR}/${UNIT_SERVICE}" <<EOF
[Unit]
Description=Backup and maintenance PostgreSQL DB (WAL-G)
Wants=postgrespro-${pgver}.service
After=postgrespro-${pgver}.service

[Service]
Type=oneshot
# Запуск от root: скрипт сам переключается на postgres через su - postgres.
ExecStart=${INSTALL_DIR}/wal-g-backup-all.sh
Environment="PATH=/sbin:/bin:/usr/sbin:/usr/bin"

[Install]
WantedBy=multi-user.target
EOF

  cat > "${SYSTEMD_DIR}/${UNIT_TIMER}" <<EOF
[Unit]
Description=Backup and maintenance PostgreSQL DB (WAL-G)

[Timer]
OnCalendar=${ONCALENDAR}
# Догнать пропущенный запуск, если хост был выключен в назначенное время.
Persistent=true

[Install]
WantedBy=timers.target
EOF

  chmod 644 "${SYSTEMD_DIR}/${UNIT_SERVICE}" "${SYSTEMD_DIR}/${UNIT_TIMER}"
  log_info "Юниты записаны: ${UNIT_SERVICE}, ${UNIT_TIMER}"
  log_info "  Wants/After : postgrespro-${pgver}.service"
  log_info "  ExecStart   : ${INSTALL_DIR}/wal-g-backup-all.sh"
  log_info "  OnCalendar  : ${ONCALENDAR}"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || log_warn "systemctl daemon-reload завершился с ошибкой."
  else
    log_warn "systemctl недоступен — пропускаю daemon-reload."
  fi
}

uninstall_units() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "${UNIT_TIMER}" 2>/dev/null || true
    systemctl stop "${UNIT_SERVICE}" 2>/dev/null || true
  fi
  rm -f "${SYSTEMD_DIR}/${UNIT_TIMER}" "${SYSTEMD_DIR}/${UNIT_SERVICE}"
  log_info "Юниты удалены."
  command -v systemctl >/dev/null 2>&1 && { systemctl daemon-reload || true; }
}

# ── Полная установка ─────────────────────────────────────────────────────────
do_install() {
  log_sect "Установка набора WAL-G"

  local pgver
  pgver="$(resolve_pgver)"

  read -rp "Каталог установки скриптов [${DEFAULT_INSTALL_DIR}]: " INSTALL_DIR
  INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"

  read -rp "Расписание бэкапа (OnCalendar) [${DEFAULT_ONCALENDAR}]: " ONCALENDAR
  ONCALENDAR="${ONCALENDAR:-$DEFAULT_ONCALENDAR}"

  install_scripts || { log_error "Установка скриптов не удалась."; exit 1; }
  install_units "$pgver"

  # Симлинк на оболочку для удобного запуска
  read -rp "Создать симлинк ${BIN_SYMLINK} → wal-g-menu.sh? [Y/n]: " mk
  if [[ "${mk,,}" != "n" ]]; then
    if ln -sfn "${INSTALL_DIR}/wal-g-menu.sh" "$BIN_SYMLINK"; then
      log_info "Симлинк создан: ${BIN_SYMLINK}"
    else
      log_warn "Не удалось создать симлинк ${BIN_SYMLINK}"
    fi
  fi

  # Включение таймера
  if command -v systemctl >/dev/null 2>&1; then
    read -rp "Включить и запустить таймер ${UNIT_TIMER} сейчас? [Y/n]: " en
    if [[ "${en,,}" != "n" ]]; then
      if systemctl enable --now "${UNIT_TIMER}"; then
        log_info "Таймер включён."
      else
        log_warn "Не удалось включить таймер."
      fi
    fi
  fi

  log_sect "Установка завершена"
  log_info "Запуск оболочки: ${INSTALL_DIR}/wal-g-menu.sh"
  [[ -L "$BIN_SYMLINK" ]] && log_info "             или: wal-g-menu"
}

do_uninstall() {
  log_sect "Удаление набора WAL-G"
  uninstall_units

  local dir
  dir="$(current_install_dir 2>/dev/null || true)"
  dir="${dir:-$DEFAULT_INSTALL_DIR}"

  read -rp "Удалить установленные скрипты из ${dir}? [y/N]: " rm_scripts
  if [[ "${rm_scripts,,}" == "y" ]]; then
    rm -f "${dir}"/wal-g-*.sh
    rmdir "${dir}" 2>/dev/null || true
    log_info "Скрипты удалены из ${dir}"
  fi

  [[ -L "$BIN_SYMLINK" ]] && { rm -f "$BIN_SYMLINK"; log_info "Симлинк ${BIN_SYMLINK} удалён."; }
  log_sect "Удаление завершено"
}

usage() {
  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ── Точка входа ──────────────────────────────────────────────────────────────
CMD="${1:-install}"
case "$CMD" in
  install)
    require_root
    do_install
    ;;
  units)
    require_root
    INSTALL_DIR="$(current_install_dir 2>/dev/null || echo "$DEFAULT_INSTALL_DIR")"
    ONCALENDAR="$(current_oncalendar 2>/dev/null || echo "$DEFAULT_ONCALENDAR")"
    PGVER_RESOLVED="$(resolve_pgver)"
    install_units "$PGVER_RESOLVED"
    ;;
  uninstall-units)
    require_root
    uninstall_units
    ;;
  uninstall)
    require_root
    do_uninstall
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    log_error "Неизвестная команда: ${CMD}"
    usage
    exit 1
    ;;
esac
