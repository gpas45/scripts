#!/usr/bin/env bash
# ==============================================================================
# wal-g-manager.sh — единый менеджер резервного копирования PostgreSQL (WAL-G)
# ==============================================================================
# Объединяет весь бывший набор pgpro/wal-g-scripts/ (cfg/list/backup/backup-all/
# delete/restore/install/menu) в один скрипт с интерактивным меню — по образцу
# pgpro-setup.sh / pg-server-manager.sh.
#
# Режимы:
#   wal-g-manager.sh                  интерактивное меню (root)
#   wal-g-manager.sh cfg              настройка конфигов WAL-G + архивации PostgreSQL
#   wal-g-manager.sh list [--full|-f] [PORT|all]   список бэкапов
#   wal-g-manager.sh backup           интерактивный delta/FULL-бэкап выбранных кластеров
#   wal-g-manager.sh backup-all       неинтерактивный прогон (для systemd-таймера) + retain
#   wal-g-manager.sh delete           удаление старых бэкапов (retain FULL N)
#   wal-g-manager.sh restore          восстановление кластера из бэкапа (в т.ч. PITR)
#   wal-g-manager.sh install          установка скрипта и systemd-задания (таймер)
#   wal-g-manager.sh units            только (пере)установить systemd-юниты
#   wal-g-manager.sh uninstall-units  удалить systemd-юниты
#   wal-g-manager.sh uninstall        удалить юниты и установленную копию скрипта
#
# Запускать от root: большинство операций требует прав root и переключения на
# пользователя postgres (su -). Сокет PostgreSQL — PGHOST_SOCKET (по умолчанию
# /tmp, конвенция PostgresPro 1C). Конфиги WAL-G — $WALG_DIR/.walg-<port>.json.
# ==============================================================================

set -uo pipefail

# ── Константы ────────────────────────────────────────────────────────────────
WALG_DIR="/etc/wal-g.d"
WALG_BIN="${WALG_BIN:-/usr/bin/wal-g}"
PG_SUPERUSER="postgres"
PGHOST_SOCKET="/tmp"          # каталог unix-сокета PostgreSQL
WALG_COMPRESSION_METHOD="brotli"

DEFAULT_INSTALL_DIR="/var/lib/pgpro/_backup/scripts"
DEFAULT_ONCALENDAR="*-*-* 01:15:00"
SYSTEMD_DIR="/etc/systemd/system"
UNIT_SERVICE="backup-pgsql.service"
UNIT_TIMER="backup-pgsql.timer"
BIN_SYMLINK="/usr/local/bin/wal-g-manager"
SELF_NAME="wal-g-manager.sh"

# ── Цвета (только в интерактивный TTY и при отсутствии NO_COLOR) ─────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
fi

log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_section() { echo -e "\n${CYAN}${BOLD}>>> $* ${NC}"; }
separator()   { echo "════════════════════════════════════════════════════════════"; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    log_error "Требуются права root."
    exit 1
  fi
}

# ==============================================================================
# ОБЩИЕ ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ==============================================================================

prompt_default() {
  local prompt="$1" default="${2-}" var
  if [[ -n "${default}" ]]; then
    read -r -p "${prompt} [${default}]: " var
    echo "${var:-$default}"
  else
    read -r -p "${prompt}: " var
    echo "${var}"
  fi
}

prompt_required() {
  local prompt="$1" var=""
  while [[ -z "$var" ]]; do
    read -r -p "${prompt}: " var
    [[ -z "$var" ]] && echo "  Значение не может быть пустым." >&2
  done
  echo "$var"
}

# Единый y/N-вопрос: принимает y, Y, yes, YES (Enter/что угодно ещё → нет).
ask_yes_no() {
  local prompt="$1" ans
  read -r -p "${prompt} [y/N]: " ans || return 1
  [[ "$ans" =~ ^([yY]|[yY][eE][sS])$ ]]
}

# Строгое подтверждение необратимого действия: нужно набрать ровно "YES".
confirm_YES() {
  local prompt="$1" ans
  read -r -p "${prompt} " ans || return 1
  [[ "$ans" == "YES" ]]
}

# Экранирование строки для безопасной вставки в JSON-значение.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"   # обратный слэш — первым
  s="${s//\"/\\\"}"   # затем двойная кавычка
  printf '%s' "$s"
}

# Чтение значения ключа из JSON-конфига WAL-G (через python3).
get_cfg_value() {
  local cfg="$1" key="$2"
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$cfg" "$key" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        val = json.load(f).get(sys.argv[2], "")
    print(str(val).strip())
except Exception:
    sys.exit(1)
PY
}

# Жив ли кластер на порту (по unix-сокету).
pg_alive() {
  local port="$1" timeout="${2:-3}"
  pg_isready -h "$PGHOST_SOCKET" -p "$port" -U "$PG_SUPERUSER" -t "$timeout" >/dev/null 2>&1
}

# SHOW <guc> с указанного кластера (пустая строка при ошибке).
pg_show() {
  local port="$1" guc="$2"
  psql -h "$PGHOST_SOCKET" -p "$port" -U "$PG_SUPERUSER" -d postgres -At -q -X \
    -c "SHOW ${guc};" 2>/dev/null
}

# Имя systemd-юнита кластера: для 5432 — штатный сервис, иначе шаблонный @<port>.
get_service_name() {
  local pgver="$1" pgport="$2"
  if [[ "$pgport" == "5432" ]]; then
    echo "postgrespro-${pgver}.service"
  else
    echo "postgrespro-${pgver}@${pgport}.service"
  fi
}

# Обнаруженные версии PostgreSQL (по systemd-юнитам и каталогам /var/lib/pgpro).
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

# Версия PostgreSQL по умолчанию для подсказок в prompt_default (первая найденная).
default_pgver() {
  local first
  first="$(detect_pgver | head -n1)"
  echo "${first:-1c-18}"
}

# Конфиги WAL-G: $WALG_DIR/.walg-<port>.json, отсортированы по имени файла.
discover_walg_configs() {
  local -a unsorted
  shopt -s nullglob
  unsorted=( "${WALG_DIR}"/.walg-*.json )
  shopt -u nullglob
  mapfile -t DISCOVERED_CFGS < <(printf '%s\n' "${unsorted[@]}" | sort)
}

cfg_port() {
  local base; base="$(basename "$1")"
  base="${base#.walg-}"; echo "${base%.json}"
}

# Перезапуск сервиса кластера после ALTER SYSTEM с ожиданием готовности.
restart_pg_service() {
  local pgver="$1" pgport="$2" svc
  svc="$(get_service_name "$pgver" "$pgport")"

  echo
  log_info "Сервис: ${svc}"

  if ! ask_yes_no "Перезапустить сервис ${svc}?"; then
    log_info "Перезапуск отменён. Выполните вручную: systemctl restart ${svc}"
    return 0
  fi

  log_info "Выполняется systemctl restart ${svc} ..."
  if ! systemctl restart "$svc"; then
    log_error "Не удалось перезапустить сервис ${svc}. Проверьте: systemctl status ${svc}"
    return 1
  fi

  local retries=10 i=1
  log_info "Ожидание готовности кластера на порту ${pgport}..."
  while (( i <= retries )); do
    if pg_alive "$pgport" 2; then
      log_info "Кластер ${pgport} запущен."
      return 0
    fi
    echo "  попытка ${i}/${retries}..."
    sleep 2
    i=$(( i + 1 ))
  done

  log_warn "Кластер ${pgport} не ответил после ${retries} попыток. Проверьте: systemctl status ${svc}"
  return 1
}

# ==============================================================================
# 1) НАСТРОЙКА (было wal-g-cfg.sh)
# ==============================================================================

declare -A CLUSTER_PGDATA=()

print_cluster_summary() {
  local -a ports=("$@")
  local port pgdata cfg_path cfg_info avail_status backend_info pgdata_info idx=1

  echo
  echo "=== Доступные кластеры ==="
  echo

  for port in "${ports[@]}"; do
    cfg_path="${WALG_DIR}/.walg-${port}.json"

    if pg_alive "$port"; then
      avail_status="OK"
      pgdata="$(pg_show "$port" data_directory)" || pgdata=""
      [[ -n "$pgdata" ]] && CLUSTER_PGDATA["$port"]="$pgdata"
    else
      avail_status="!!"
      pgdata=""
    fi

    if [[ -f "$cfg_path" ]]; then
      if grep -q '"WALG_S3_PREFIX"' "$cfg_path" 2>/dev/null; then
        backend_info="s3"
      elif grep -q '"WALG_FILE_PREFIX"' "$cfg_path" 2>/dev/null; then
        backend_info="file"
      else
        backend_info="unknown"
      fi
      cfg_info="конфиг=есть (${backend_info})"
    else
      cfg_info="конфиг=отсутствует"
    fi

    [[ -n "$pgdata" ]] && pgdata_info="PGDATA=${pgdata}" || pgdata_info="PGDATA недоступен"

    printf "  %2d. [ %s ] Порт %-5s  |  %s, %s\n" \
      "$idx" "$avail_status" "$port" "$pgdata_info" "$cfg_info"
    idx=$(( idx + 1 ))
  done

  echo
  printf "   0. Отмена\n"
  echo
}

select_ports_by_index() {
  local -n _ports_ref="$1"
  local total="${#_ports_ref[@]}"
  local input sel port result=()

  while true; do
    read -r -p "Введите номера через пробел или 'all' для всех [all]: " input
    input="${input:-all}"

    if [[ "$input" == "0" ]]; then
      SELECTED_PORTS=()
      return 1
    fi

    if [[ "$input" == "all" ]]; then
      SELECTED_PORTS=("${_ports_ref[@]}")
      return 0
    fi

    result=()
    local valid=1
    for sel in $input; do
      if ! [[ "$sel" =~ ^[0-9]+$ ]]; then
        echo "WARN: '${sel}' не является числом, повторите ввод." >&2
        valid=0; break
      fi
      if (( sel < 1 || sel > total )); then
        echo "WARN: номер ${sel} вне диапазона 1–${total}, повторите ввод." >&2
        valid=0; break
      fi
      port="${_ports_ref[$(( sel - 1 ))]}"
      result+=("$port")
    done

    if (( valid )) && (( ${#result[@]} > 0 )); then
      SELECTED_PORTS=("${result[@]}")
      return 0
    fi
  done
}

configure_pg_instance() {
  local pgport="$1" pgdata="$2" walgcfg="$3"

  local -a PSQL=(
    psql -h "$PGHOST_SOCKET" -p "$pgport" -U "$PG_SUPERUSER" -d postgres
    -At -q -X -v ON_ERROR_STOP=1
  )

  local logdir
  logdir="$("${PSQL[@]}" -c "SHOW log_directory;" 2>/dev/null)" || {
    log_error "Не удалось получить log_directory для ${pgport}"
    return 1
  }

  local pglogdir
  if [[ "$logdir" = /* ]]; then
    pglogdir="$logdir"
  else
    pglogdir="${pgdata%/}/${logdir}"
  fi

  declare -A WANT=(
    [wal_level]="replica"
    [archive_mode]="on"
    [archive_timeout]="60s"
    [archive_command]="${WALG_BIN} wal-push \"%p\" --config ${walgcfg} >> ${pglogdir}/archive_command.log 2>&1"
    [restore_command]="${WALG_BIN} wal-fetch \"%f\" \"%p\" --config ${walgcfg} >> ${pglogdir}/restore_command.log 2>&1"
  )
  declare -A RESTART=(
    [wal_level]=1
    [archive_mode]=1
    [archive_command]=0
    [archive_timeout]=0
    [restore_command]=0
  )

  local pg_out
  pg_out="$("${PSQL[@]}" -F '|' -c "
    SELECT name,
           CASE WHEN COALESCE(unit,'') = '' THEN setting
                ELSE setting || unit
           END AS setting
    FROM pg_settings
    WHERE name IN (
      'wal_level','archive_mode','archive_command',
      'archive_timeout','restore_command'
    )
    ORDER BY name;
  " 2>&1)" || {
    log_error "Не удалось получить параметры pg_settings для ${pgport}"
    return 1
  }

  declare -A CUR=()
  local k v
  while IFS='|' read -r k v; do
    [[ -n "$k" ]] && CUR["$k"]="$v"
  done <<< "$pg_out"

  local -a PARAMS=(wal_level archive_mode archive_command archive_timeout restore_command)
  local p
  for p in "${PARAMS[@]}"; do
    if [[ -z "${CUR[$p]+x}" ]]; then
      log_error "Параметр '${p}' не получен из pg_settings"
      return 1
    fi
  done

  local -a TO_CHANGE=()
  local restart_needed=0
  for p in "${PARAMS[@]}"; do
    if [[ "${CUR[$p]}" != "${WANT[$p]}" ]]; then
      TO_CHANGE+=("$p")
      (( restart_needed |= RESTART[$p] )) || true
    fi
  done

  if (( ${#TO_CHANGE[@]} == 0 )); then
    log_info "Параметры PostgreSQL ${pgport} уже соответствуют целевым."
    PG_RESTART_NEEDED=0
    return 0
  fi

  echo
  echo "=== Параметры PostgreSQL (${pgport}) ==="
  for p in "${PARAMS[@]}"; do
    local cur="${CUR[$p]}" want="${WANT[$p]}"
    if [[ "$cur" != "$want" ]]; then
      local extra=""
      (( RESTART[$p] )) && extra=" (требуется перезапуск)"
      printf "  [CHG] %-20s\n        текущий : %s\n        целевой : %s%s\n" \
        "$p" "${cur:-<пусто>}" "$want" "$extra"
    else
      printf "  [OK ] %-20s = %s\n" "$p" "$cur"
    fi
  done
  echo

  if ! ask_yes_no "Применить ${#TO_CHANGE[@]} изменения для ${pgport}?"; then
    log_info "Изменения ${pgport} отменены пользователем."
    PG_RESTART_NEEDED=0
    return 0
  fi

  local sql=""
  for p in "${TO_CHANGE[@]}"; do
    local esc="${WANT[$p]//\'/\'\'}"
    sql+="ALTER SYSTEM SET ${p} = '${esc}';"$'\n'
  done

  if ! "${PSQL[@]}" -c "$sql" >/dev/null; then
    log_error "Не удалось применить параметры PostgreSQL ${pgport}"
    return 1
  fi
  for p in "${TO_CHANGE[@]}"; do echo "  SET ${p}"; done

  if ! "${PSQL[@]}" -c "SELECT pg_reload_conf();" >/dev/null 2>&1; then
    log_warn "Не удалось выполнить pg_reload_conf() ${pgport}"
  fi

  if (( restart_needed )); then
    log_info "Параметры wal_level/archive_mode требуют перезапуска сервиса."
    PG_RESTART_NEEDED=1
  else
    log_info "Параметры обновлены без необходимости перезапуска."
    PG_RESTART_NEEDED=0
  fi
}

action_configure() {
  require_root
  # umask 077 закрывает окно world-readable для секретов между созданием файла
  # и chmod 600 (снимается в конце функции, чтобы не влиять на остальное меню).
  local old_umask; old_umask="$(umask)"
  umask 077

  CLUSTER_PGDATA=()
  local -a FOUND_PORTS=() SELECTED_PORTS=()

  if command -v ss >/dev/null 2>&1; then
    mapfile -t FOUND_PORTS < <(ss -tlnp 2>/dev/null | grep postgres | grep -oP ':\K\d+' | sort -un)
  fi

  if (( ${#FOUND_PORTS[@]} > 0 )); then
    print_cluster_summary "${FOUND_PORTS[@]}"
    select_ports_by_index FOUND_PORTS || { log_info "Отменено."; umask "$old_umask"; return 0; }
  else
    log_warn "Кластеры не обнаружены автоматически (нужны права root для ss -p)."
    local manual; manual="$(prompt_required 'Укажите порты через пробел (например: 5432 5433)')"
    read -r -a SELECTED_PORTS <<< "$manual"
  fi

  if (( ${#SELECTED_PORTS[@]} == 0 )); then
    log_error "Список пуст — нечего настраивать"
    umask "$old_umask"; return 1
  fi

  echo; echo "Выбраны порты: ${SELECTED_PORTS[*]}"; echo

  echo "Тип хранилища:"
  echo "  1. S3"
  echo "  2. Файловое"
  echo "  0. Отмена"
  echo
  local BACKEND BACKEND_SEL
  while true; do
    read -r -p "Выбор [1]: " BACKEND_SEL
    BACKEND_SEL="${BACKEND_SEL:-1}"
    case "${BACKEND_SEL}" in
      1) BACKEND="s3";   break ;;
      2) BACKEND="file"; break ;;
      0) log_info "Отменено."; umask "$old_umask"; return 0 ;;
      *) echo "WARN: введите 0, 1 или 2." >&2 ;;
    esac
  done
  log_info "Тип хранилища = ${BACKEND}"
  echo

  local PGVER WALG_DELTA_MAX_STEPS
  PGVER="$(prompt_default 'Версия PostgreSQL (PGVER)' "$(default_pgver)")"

  WALG_DELTA_MAX_STEPS="$(prompt_default 'WALG_DELTA_MAX_STEPS' '6')"
  if ! [[ "$WALG_DELTA_MAX_STEPS" =~ ^[0-9]+$ ]]; then
    log_error "WALG_DELTA_MAX_STEPS должен быть целым числом"
    umask "$old_umask"; return 1
  fi

  local J_AWS_ENDPOINT="" J_AWS_REGION="" J_AWS_ACCESS_KEY_ID="" J_AWS_SECRET_ACCESS_KEY="" J_S3_BUCKET=""
  local J_WALG_FILE_PREFIX_BASE=""
  if [[ "$BACKEND" == "s3" ]]; then
    local AWS_ENDPOINT AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY S3_BUCKET
    AWS_ENDPOINT="$(prompt_default     'AWS_ENDPOINT'        's3.ru-3.storage.selcloud.ru:443')"
    AWS_REGION="$(prompt_default       'AWS_REGION'          'ru-3')"
    AWS_ACCESS_KEY_ID="$(prompt_required     'AWS_ACCESS_KEY_ID')"
    AWS_SECRET_ACCESS_KEY="$(prompt_required 'AWS_SECRET_ACCESS_KEY')"
    S3_BUCKET="$(prompt_required             'S3_BUCKET')"

    [[ "$S3_BUCKET" != s3://* ]] && S3_BUCKET="s3://${S3_BUCKET}"
    S3_BUCKET="${S3_BUCKET%/}"

    J_AWS_ENDPOINT="$(json_escape "$AWS_ENDPOINT")"
    J_AWS_REGION="$(json_escape "$AWS_REGION")"
    J_AWS_ACCESS_KEY_ID="$(json_escape "$AWS_ACCESS_KEY_ID")"
    J_AWS_SECRET_ACCESS_KEY="$(json_escape "$AWS_SECRET_ACCESS_KEY")"
    J_S3_BUCKET="$(json_escape "$S3_BUCKET")"
  else
    local WALG_FILE_PREFIX_BASE
    WALG_FILE_PREFIX_BASE="$(prompt_default 'Базовый каталог WALG_FILE_PREFIX' '/backup')"
    WALG_FILE_PREFIX_BASE="${WALG_FILE_PREFIX_BASE%/}"
    J_WALG_FILE_PREFIX_BASE="$(json_escape "$WALG_FILE_PREFIX_BASE")"
  fi

  if ! install -d -m 755 "$WALG_DIR" 2>/dev/null; then
    log_error "Нет прав на создание каталога ${WALG_DIR}"
    umask "$old_umask"; return 1
  fi

  local PGPORT
  for PGPORT in "${SELECTED_PORTS[@]}"; do
    echo
    echo "━━━ Порт ${PGPORT} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if ! [[ "$PGPORT" =~ ^[0-9]+$ ]]; then
      log_warn "Некорректный номер '${PGPORT}', пропуск"
      continue
    fi

    local SVC_NAME; SVC_NAME="$(get_service_name "$PGVER" "$PGPORT")"
    log_info "Сервис systemd: ${SVC_NAME}"

    local CFG="${WALG_DIR}/.walg-${PGPORT}.json"

    if ! pg_alive "$PGPORT"; then
      log_warn "Кластер на порту ${PGPORT} недоступен, пропуск"
      continue
    fi

    local PGDATA
    if [[ -n "${CLUSTER_PGDATA[$PGPORT]+x}" ]]; then
      PGDATA="${CLUSTER_PGDATA[$PGPORT]}"
    else
      PGDATA="$(pg_show "$PGPORT" data_directory)" || PGDATA=""
    fi

    if [[ -z "$PGDATA" || ! -d "$PGDATA" ]]; then
      log_warn "Не удалось определить PGDATA для порта ${PGPORT}, пропуск"
      continue
    fi
    log_info "PGDATA = ${PGDATA}"

    local WRITE_CFG=1
    if [[ -f "$CFG" ]]; then
      if ask_yes_no "Файл ${CFG} уже существует. Перезаписать?"; then
        if ! cp -p -- "$CFG" "${CFG}.bak"; then
          log_error "Не удалось создать резервную копию ${CFG}.bak, пропуск"
          continue
        fi
        log_info "Создана резервная копия ${CFG}.bak"
      else
        log_info "Конфиг ${CFG} оставлен без изменений."
        WRITE_CFG=0
      fi
    fi

    if (( WRITE_CFG )); then
      if [[ "$BACKEND" == "s3" ]]; then
        cat > "$CFG" <<EOF
{
  "AWS_ENDPOINT":            "${J_AWS_ENDPOINT}",
  "AWS_REGION":              "${J_AWS_REGION}",
  "WALG_S3_PREFIX":          "${J_S3_BUCKET}/${PGPORT}",
  "AWS_ACCESS_KEY_ID":       "${J_AWS_ACCESS_KEY_ID}",
  "AWS_SECRET_ACCESS_KEY":   "${J_AWS_SECRET_ACCESS_KEY}",
  "WALG_COMPRESSION_METHOD": "${WALG_COMPRESSION_METHOD}",
  "WALG_DELTA_MAX_STEPS":    "${WALG_DELTA_MAX_STEPS}",
  "PGPORT":                  "${PGPORT}",
  "PGHOST":                  "${PGHOST_SOCKET}",
  "PGDATA":                  "$(json_escape "$PGDATA")",
  "PGSSLMODE":               "disable"
}
EOF
      else
        cat > "$CFG" <<EOF
{
  "WALG_FILE_PREFIX":        "${J_WALG_FILE_PREFIX_BASE}/${PGPORT}",
  "WALG_COMPRESSION_METHOD": "${WALG_COMPRESSION_METHOD}",
  "WALG_DELTA_MAX_STEPS":    "${WALG_DELTA_MAX_STEPS}",
  "PGPORT":                  "${PGPORT}",
  "PGHOST":                  "${PGHOST_SOCKET}",
  "PGDATA":                  "$(json_escape "$PGDATA")",
  "PGSSLMODE":               "disable"
}
EOF
      fi

      chmod 600 "$CFG"
      chown postgres:postgres "$CFG" 2>/dev/null || log_warn "Не удалось установить владельца postgres для ${CFG}"
      log_info "Конфиг записан: ${CFG}"
    fi

    PG_RESTART_NEEDED=0
    if configure_pg_instance "$PGPORT" "$PGDATA" "$CFG"; then
      if (( PG_RESTART_NEEDED )); then
        restart_pg_service "$PGVER" "$PGPORT" \
          || log_warn "Перезапуск ${PGPORT} не выполнен, перехожу к следующему кластеру."
      fi
    else
      log_warn "Настройка параметров PostgreSQL ${PGPORT} не завершена, пропуск."
    fi
  done

  umask "$old_umask"
  echo; log_info "Настройка завершена."
}

# ==============================================================================
# 2) СПИСОК БЭКАПОВ (было wal-g-list.sh / show_backups из wal-g-delete.sh)
# ==============================================================================

# Постраничный вывод: пейджер только когда вывод не влезает на экран.
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

# Кол-во FULL-бэкапов из последнего run_backup_list (переиспользуется action_delete).
LAST_FULL_COUNT=0

# Вывод backup-list одного конфига. $2 (опционально) = "full" — только FULL.
run_backup_list() {
  local cfg="$1" full_only="${2:-}" port
  port="$(cfg_port "$cfg")"

  echo
  echo -e "${BOLD}=== WAL-G backup-list · Порт ${port} ===${NC}"
  echo

  if [[ ! -r "$cfg" ]]; then
    echo -e "${RED}ERROR: конфиг недоступен для чтения: ${cfg}${NC}" >&2
    return 1
  fi

  local out rc
  out="$("$WALG_BIN" backup-list --pretty --config "$cfg" 2>&1)"
  rc=$?
  if (( rc != 0 )); then
    echo -e "${RED}ERROR: backup-list завершился с кодом ${rc}${NC}" >&2
    [[ -n "$out" ]] && echo "$out" >&2
    return 1
  fi

  local total delta full
  total="$(printf '%s\n' "$out" | grep -c 'base_' || true)"
  delta="$(printf '%s\n' "$out" | grep -c '_D_'  || true)"
  full=$(( total - delta ))
  LAST_FULL_COUNT=$full

  if (( total == 0 )); then
    echo "  (бэкапы не найдены)"
    echo
    return 0
  fi

  if [[ "$full_only" == "full" ]]; then
    if (( full == 0 )); then
      echo "  (FULL-бэкапов нет; всего delta: ${delta})"
    else
      printf '%s\n' "$out" | grep -v '_D_' || true
    fi
  else
    # Таблица: FULL — зелёным, delta (_D_) — жёлтым, заголовок без цвета.
    printf '%s\n' "$out" | awk -v g="${GREEN}" -v y="${YELLOW}" -v r="${NC}" '
      NR==1 { print "  " $0; next }
      /_D_/ { print "  " y $0 r; next }
            { print "  " g $0 r }
    '
  fi

  local latest_line latest_name latest_date summary
  latest_line="$(printf '%s\n' "$out" | grep 'base_' | tail -n1 || true)"
  latest_name="$(printf '%s\n' "$latest_line" | grep -oE 'base_[0-9A-Za-z_]+' | head -n1 || true)"
  latest_date="$(printf '%s\n' "$latest_line" \
    | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2})?' | head -n1 || true)"

  summary="FULL: ${full} · delta: ${delta} · всего: ${total}"
  [[ -n "$latest_name" ]] && summary+=" · последний: ${latest_name}"
  [[ -n "$latest_date" ]] && summary+=" (${latest_date})"

  echo
  echo -e "${CYAN}  Сводка: ${summary}${NC}"
  return 0
}

run_selected_lists() {
  local full_only="$1"; shift
  local errors=0 cfg tmpfile
  tmpfile="$(mktemp "${TMPDIR:-/tmp}/walg-list.XXXXXX")" || {
    log_error "Не удалось создать временный файл"
    return 1
  }

  for cfg in "$@"; do
    run_backup_list "$cfg" "$full_only" >>"$tmpfile" || (( errors++ )) || true
  done

  page_output <"$tmpfile"
  rm -f "$tmpfile"

  if (( errors > 0 )); then
    log_warn "${errors} конфиг(ов) завершились с ошибкой"
    return 5
  fi
  return 0
}

action_list() {
  if [[ ! -x "$WALG_BIN" ]]; then
    log_error "wal-g не найден или не исполняемый: $WALG_BIN"
    return 1
  fi
  if [[ ! -d "$WALG_DIR" ]]; then
    log_error "Каталог не найден: $WALG_DIR"
    return 1
  fi

  local -a CFGS
  discover_walg_configs; CFGS=("${DISCOVERED_CFGS[@]}")
  if (( ${#CFGS[@]} == 0 )); then
    log_error "Конфиги не найдены в ${WALG_DIR} (ожидались .walg-*.json)"
    return 2
  fi

  local full_only="" input=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --full|-f) full_only="full"; shift ;;
      --help|-h)
        echo "Использование: $SELF_NAME list [--full|-f] [PORT|all]"
        return 0
        ;;
      -*) log_error "Неизвестная опция: $1"; return 1 ;;
      *) input="$1"; shift ;;
    esac
  done

  if [[ -n "$input" ]]; then
    if [[ "${input,,}" == "all" ]]; then
      run_selected_lists "$full_only" "${CFGS[@]}"; return $?
    fi
    if [[ ! "$input" =~ ^[1-9][0-9]{0,4}$ ]] || (( input > 65535 )); then
      log_error "Некорректный порт: '$input' (ожидается 1–65535)"
      return 3
    fi
    local wcf="${WALG_DIR}/.walg-${input}.json"
    if [[ ! -f "$wcf" ]]; then
      log_error "Конфиг для порта $input не найден: $wcf"
      return 4
    fi
    run_selected_lists "$full_only" "$wcf"; return $?
  fi

  if [[ ! -t 0 ]]; then
    log_error "Нужен TTY либо аргумент. Использование: $SELF_NAME list [--full|-f] [PORT|all]"
    return 1
  fi

  echo
  echo -e "${BOLD}=== Доступные кластеры ===${NC}"
  echo
  local i=1 cfg port
  for cfg in "${CFGS[@]}"; do
    port="$(cfg_port "$cfg")"
    if [[ -r "$cfg" ]]; then
      echo -e "   ${BOLD}${i}.${NC} [ ${GREEN}OK${NC} ] Порт ${port}"
    else
      echo -e "   ${BOLD}${i}.${NC} [ ${RED}FAIL${NC} ] Порт ${port} — конфиг недоступен"
    fi
    i=$(( i + 1 ))
  done
  local total=${#CFGS[@]}
  local all_idx=$(( total + 1 ))
  echo
  echo -e "   ${BOLD}${all_idx}.${NC} Все кластеры"
  echo -e "   ${BOLD}0.${NC} Отмена"
  echo

  local -a selected=() choice
  while true; do
    read -r -p "Выберите номер [0–${all_idx}]: " choice
    [[ "$choice" == "0" ]] && { log_info "Отменено."; return 0; }
    if [[ ! "$choice" =~ ^[0-9]+$ ]]; then
      echo -e "${RED}Некорректный ввод.${NC}" >&2; continue
    fi
    if (( choice == all_idx )); then selected=("${CFGS[@]}"); break; fi
    if (( choice >= 1 && choice <= total )); then selected=("${CFGS[choice-1]}"); break; fi
    echo -e "${RED}Номер вне диапазона.${NC}" >&2
  done

  if [[ -z "$full_only" ]]; then
    echo
    if ask_yes_no "Показывать только FULL-бэкапы?"; then full_only="full"; fi
  fi

  run_selected_lists "$full_only" "${selected[@]}"
}

# ==============================================================================
# 3) ИНТЕРАКТИВНЫЙ БЭКАП (было wal-g-backup.sh)
# ==============================================================================

action_backup() {
  require_root

  local PGVER; PGVER="$(prompt_default 'Версия PostgreSQL (PGVER)' "$(default_pgver)")"

  local -a FOUND_PORTS=() VALID_PORTS=()
  declare -A PORT_DATA=()

  if command -v ss >/dev/null 2>&1; then
    mapfile -t FOUND_PORTS < <(ss -tlnp 2>/dev/null | grep -i postgres | grep -oP ':\K\d+' | sort -u)
  fi

  check_backup_port() {
    local port="$1" pgdata
    local cfg="${WALG_DIR}/.walg-${port}.json"
    if [[ ! -f "$cfg" ]]; then
      echo "  [SKIP] Порт ${port}: конфиг ${cfg} не найден"; return 1
    fi
    if ! pg_alive "$port"; then
      echo "  [SKIP] Порт ${port}: кластер недоступен"; return 1
    fi
    pgdata="$(pg_show "$port" data_directory)"
    if [[ -z "$pgdata" || ! -d "$pgdata" ]]; then
      echo "  [SKIP] Порт ${port}: не удалось определить PGDATA"; return 1
    fi
    PORT_DATA["$port"]="$pgdata"
    return 0
  }

  scan_backup_ports() {
    local p
    for p in "$@"; do check_backup_port "$p" && VALID_PORTS+=("$p"); done
  }

  echo; echo "=== Доступные кластеры ==="
  if (( ${#FOUND_PORTS[@]} > 0 )); then
    scan_backup_ports "${FOUND_PORTS[@]}"
  else
    echo "  Автообнаружение не дало результатов."
  fi

  if (( ${#VALID_PORTS[@]} == 0 )); then
    echo
    log_warn "Не найдено ни одного кластера с конфигом WAL-G."
    local manual; manual="$(prompt_required 'Укажите порты вручную через пробел (например: 5432 5433)')"
    local -a manual_ports=(); read -r -a manual_ports <<< "$manual"
    scan_backup_ports "${manual_ports[@]}"
    if (( ${#VALID_PORTS[@]} == 0 )); then
      log_error "Нет доступных кластеров с валидной конфигурацией — выход."
      return 1
    fi
  fi

  echo
  local i p cfg
  for i in "${!VALID_PORTS[@]}"; do
    p="${VALID_PORTS[$i]}"; cfg="${WALG_DIR}/.walg-${p}.json"
    echo "  $((i+1)). [ OK ] Порт ${p}  |  PGDATA=${PORT_DATA[$p]}, конфиг=${cfg}"
  done
  echo "  0. Отмена"
  echo

  local sel; sel="$(prompt_default "Укажите номера через пробел, 'all' для всех или '0' для отмены" 'all')"
  if [[ "$sel" == "0" || "${sel,,}" == "q" || "${sel,,}" == "exit" ]]; then
    log_info "Отменено."; return 0
  fi

  local -a SELECTED_PORTS=()
  if [[ "${sel,,}" == "all" ]]; then
    SELECTED_PORTS=("${VALID_PORTS[@]}")
  else
    local -a nums=(); read -r -a nums <<< "$sel"
    local num idx
    for num in "${nums[@]}"; do
      if ! [[ "$num" =~ ^[0-9]+$ ]]; then echo "  [WARN] '${num}' — не число, пропускаем." >&2; continue; fi
      idx=$(( num - 1 ))
      if (( idx < 0 || idx >= ${#VALID_PORTS[@]} )); then echo "  [WARN] Номер ${num} вне диапазона — пропускаем." >&2; continue; fi
      SELECTED_PORTS+=("${VALID_PORTS[$idx]}")
    done
  fi

  if (( ${#SELECTED_PORTS[@]} == 0 )); then
    log_error "Нет кластера для бэкапа — выход."
    return 1
  fi

  echo
  local force_full=false
  ask_yes_no 'Запустить FULL-бэкап для всех выбранных кластеров?' && force_full=true
  if [[ "$force_full" == true ]]; then
    echo "  Режим: FULL-бэкап."
  else
    echo "  Режим: Delta (при отсутствии базового — автоматически FULL)."
  fi

  echo; echo "=== Запуск бэкапов ==="
  local errors=0 PGPORT PGDATA wcf
  for PGPORT in "${SELECTED_PORTS[@]}"; do
    PGDATA="${PORT_DATA[$PGPORT]}"
    wcf="${WALG_DIR}/.walg-${PGPORT}.json"

    echo
    echo ">>> Бэкап: порт=${PGPORT}  PGDATA=${PGDATA}"
    echo "    Конфиг: ${wcf}"

    if [[ "$force_full" == true ]]; then
      echo "    Запуск FULL-бэкапа..."
      if su - "$PG_SUPERUSER" -c "'${WALG_BIN}' backup-push --full --config '${wcf}' '${PGDATA}'"; then
        echo "    [OK] FULL бэкап ${PGPORT} завершён успешно."
      else
        echo "    [FAIL] FULL бэкап ${PGPORT} завершился с ошибкой!" >&2
        (( errors++ )) || true
      fi
    else
      echo "    Попытка delta-бэкапа..."
      if ! su - "$PG_SUPERUSER" -c "'${WALG_BIN}' backup-push --config '${wcf}' '${PGDATA}'"; then
        echo "    Delta не удалась — пробуем FULL бэкап..." >&2
        if su - "$PG_SUPERUSER" -c "'${WALG_BIN}' backup-push --full --config '${wcf}' '${PGDATA}'"; then
          echo "    [OK] FULL бэкап ${PGPORT} завершён успешно."
        else
          echo "    [FAIL] FULL бэкап ${PGPORT} завершился с ошибкой!" >&2
          (( errors++ )) || true
        fi
      else
        echo "    [OK] Delta бэкап ${PGPORT} завершён успешно."
      fi
    fi
  done

  echo; echo "=== Итог ==="
  echo "  Всего бэкапов: ${#SELECTED_PORTS[@]}"
  echo "  Ошибок:        ${errors}"
  (( errors == 0 ))
}

# ==============================================================================
# 4) НЕИНТЕРАКТИВНЫЙ ПРОГОН ДЛЯ SYSTEMD (было wal-g-backup-all.sh)
# ==============================================================================

backup_cluster_noninteractive() {
  local cfg="$1" port="$2" pgdata="$3" retain="${RETAIN:-3}"
  local logdir="${pgdata}/log"
  local logfile="${logdir}/wal-g-backup-${port}-$(date +%F).log"

  mkdir -p "${logdir}" && chown "${PG_SUPERUSER}:${PG_SUPERUSER}" "${logdir}" || {
    log_error "Не удалось создать каталог логов: ${logdir}"
    return 1
  }

  log_info "Запуск резервного копирования: port=${port}, cfg=${cfg}"
  log_info "Лог: ${logfile}"

  # Все значения передаём через явные переменные в heredoc,
  # чтобы не зависеть от окружения login shell.
  su - "${PG_SUPERUSER}" -s /bin/bash <<SHELL
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

  if (( backup_rc != 0 )); then
    echo "===== \$(date '+%F %T') ===== WARN delta rc=\${backup_rc}, запускаем FULL ====="
    backup_rc=0

    echo "===== \$(date '+%F %T') ===== START backup-push --full port=\${PORT} ====="

    "\${WALG_BIN}" backup-push --full --config "\${CFG}" "\${PGDATA}" \
      || backup_rc=\$?

    echo "===== \$(date '+%F %T') ===== END backup-push --full rc=\${backup_rc} ====="
  fi

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

if (( backup_rc != 0 || delete_rc != 0 )); then
  exit 1
fi
exit 0
SHELL
}

action_backup_all() {
  require_root

  local fail=0
  [[ -d "${WALG_DIR}" ]] || { log_error "Каталог конфигов не найден: ${WALG_DIR}"; fail=1; }
  [[ -x "${WALG_BIN}" ]] || { log_error "WAL-G бинарник не найден / не исполняемый: ${WALG_BIN}"; fail=1; }
  command -v python3 &>/dev/null || { log_error "python3 не найден в PATH"; fail=1; }
  (( fail == 0 )) || return 1

  local -a confs
  discover_walg_configs; confs=("${DISCOVERED_CFGS[@]}")
  if (( ${#confs[@]} == 0 )); then
    log_error "Конфиги не найдены: ${WALG_DIR}/.walg-*.json"
    return 1
  fi
  log_info "Найдено конфигов: ${#confs[@]}"

  local errors=0 cfg port pgdata
  for cfg in "${confs[@]}"; do
    port="$(get_cfg_value "${cfg}" PGPORT)" || {
      log_error "Ошибка парсинга порта: ${cfg} — пропуск"; (( errors++ )) || true; continue
    }
    if [[ ! "${port}" =~ ^[0-9]+$ ]]; then
      log_error "PGPORT не задан или некорректен: ${cfg} — пропуск"; (( errors++ )) || true; continue
    fi

    pgdata="$(get_cfg_value "${cfg}" PGDATA)" || {
      log_error "Ошибка парсинга PGDATA: ${cfg} — пропуск"; (( errors++ )) || true; continue
    }
    if [[ -z "${pgdata}" ]]; then
      log_error "PGDATA не задан в конфиге: ${cfg} — пропуск"; (( errors++ )) || true; continue
    fi
    if [[ ! -d "${pgdata}" ]]; then
      log_error "PGDATA не существует: '${pgdata}' (cfg=${cfg}) — пропуск"; (( errors++ )) || true; continue
    fi

    backup_cluster_noninteractive "${cfg}" "${port}" "${pgdata}" || {
      log_error "Ошибка резервного копирования: port=${port}, cfg=${cfg}"; (( errors++ )) || true
    }
  done

  if (( errors > 0 )); then
    log_error "Завершено с ошибками: ${errors} кластер(ов)"
    return 1
  fi
  log_info "Все резервные копии успешно созданы"
  return 0
}

# ==============================================================================
# 5) УДАЛЕНИЕ СТАРЫХ БЭКАПОВ (было wal-g-delete.sh)
# ==============================================================================

action_delete() {
  require_root

  local fail=0
  [[ -d "${WALG_DIR}" ]] || { log_error "Каталог конфигов не найден: ${WALG_DIR}"; fail=1; }
  [[ -x "${WALG_BIN}" ]] || { log_error "WAL-G не найден / не исполняемый: ${WALG_BIN}"; fail=1; }
  command -v python3 &>/dev/null || { log_error "python3 не найден в PATH"; fail=1; }
  (( fail == 0 )) || return 1

  local -a cfg_files
  discover_walg_configs; cfg_files=("${DISCOVERED_CFGS[@]}")
  if (( ${#cfg_files[@]} == 0 )); then
    log_error "Конфиги не найдены: ${WALG_DIR}/.walg-*.json"
    return 1
  fi

  declare -A port_to_cfg
  local cfg port
  for cfg in "${cfg_files[@]}"; do
    port="$(get_cfg_value "${cfg}" PGPORT 2>/dev/null)" || continue
    [[ "${port}" =~ ^[0-9]+$ ]] || continue
    port_to_cfg["${port}"]="${cfg}"
  done
  if (( ${#port_to_cfg[@]} == 0 )); then
    log_error "Не найдено ни одного корректного конфига с PGPORT"
    return 1
  fi

  echo; separator
  echo "  Доступные кластеры PostgreSQL (WAL-G конфиги)"
  separator

  local -a sorted_ports=()
  mapfile -t sorted_ports < <(printf '%s\n' "${!port_to_cfg[@]}" | sort -n)

  local i=1
  declare -A idx_to_port
  for port in "${sorted_ports[@]}"; do
    printf "  [%d] порт %-6s  →  %s\n" "$i" "${port}" "${port_to_cfg[${port}]}"
    idx_to_port[$i]="${port}"
    (( i++ ))
  done
  separator; echo

  local choice
  while true; do
    read -rp "Введите номер кластера (1-$(( i-1 ))), 0 — отмена: " choice
    [[ "$choice" == "0" ]] && { log_info "Отменено."; return 0; }
    [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= i-1 )) && break
    echo "  ✗ Некорректный выбор, попробуйте снова."
  done

  local selected_port="${idx_to_port[${choice}]}"
  local selected_cfg="${port_to_cfg[${selected_port}]}"
  log_info "Выбран кластер: порт=${selected_port}, конфиг=${selected_cfg}"

  run_backup_list "${selected_cfg}" || return 1

  if (( LAST_FULL_COUNT == 0 )); then
    log_info "FULL-бэкапов нет — удалять нечего."
    return 0
  fi

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

  echo; separator
  echo "  Параметры удаления:"
  echo "  Кластер        : порт ${selected_port}"
  echo "  Конфиг         : ${selected_cfg}"
  echo "  Оставить FULL  : ${retain}"
  echo "  Команда        : wal-g delete retain FULL ${retain} --confirm"
  separator; echo

  confirm_YES "Для подтверждения введите YES (заглавными буквами):" || {
    echo; log_info "Операция отменена пользователем."; return 0
  }

  echo; log_info "Запуск удаления: port=${selected_port}, retain FULL ${retain}"; echo

  "${WALG_BIN}" delete retain FULL "${retain}" --confirm --config "${selected_cfg}"
  local rc=$?
  echo
  if (( rc == 0 )); then
    log_info "Удаление завершено успешно (port=${selected_port})"
  else
    log_error "Удаление завершилось с ошибкой rc=${rc} (port=${selected_port})"
    return "${rc}"
  fi
}

# ==============================================================================
# 6) ВОССТАНОВЛЕНИЕ (было wal-g-restore.sh)
# ==============================================================================

action_restore() {
  require_root

  local -a config_files
  discover_walg_configs; config_files=("${DISCOVERED_CFGS[@]}")
  if (( ${#config_files[@]} == 0 )); then
    log_error "Конфиги не найдены в $WALG_DIR"
    return 1
  fi

  local -a ports=()
  local cfg
  for cfg in "${config_files[@]}"; do ports+=("$(cfg_port "$cfg")"); done

  echo
  echo -e "${BOLD}Доступные порты PostgreSQL:${NC}"
  local i
  for i in "${!ports[@]}"; do
    echo -e "  ${CYAN}[$((i+1))]${NC} Порт: ${BOLD}${ports[$i]}${NC}  →  ${config_files[$i]}"
  done
  echo -e "  ${CYAN}[0]${NC} Отмена"
  echo

  local choice pgport walg_cfg
  while true; do
    read -rp "Выберите номер (0-${#ports[@]}): " choice
    [[ "$choice" == "0" ]] && { log_info "Отменено."; return 0; }
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ports[@]} )); then
      pgport="${ports[$((choice-1))]}"
      walg_cfg="${config_files[$((choice-1))]}"
      break
    fi
    log_warn "Некорректный ввод, попробуйте снова."
  done

  log_info "Выбран порт: ${BOLD}$pgport${NC}"
  log_info "Конфиг:      ${BOLD}$walg_cfg${NC}"

  log_section "Определение PGDATA"
  local restore_pgdata pgver pgver_default
  restore_pgdata="$(get_cfg_value "$walg_cfg" PGDATA 2>/dev/null || true)"
  pgver="$(default_pgver)"
  if [[ -n "$restore_pgdata" ]]; then
    log_info "PGDATA из конфига: ${BOLD}$restore_pgdata${NC}"
  else
    restore_pgdata="/var/lib/pgpro/${pgver}/data-${pgport}"
    log_warn "PGDATA из конфига не получен; путь по умолчанию: ${BOLD}$restore_pgdata${NC}"
  fi

  if ! ask_yes_no "Использовать путь ${restore_pgdata}?"; then
    local custom_data; custom_data="$(prompt_required 'Введите путь PGDATA')"
    restore_pgdata="$custom_data"
    log_info "Используется путь: ${BOLD}$restore_pgdata${NC}"
  fi

  # Версия PostgreSQL нужна для имени systemd-юнита. Неверная версия → проверка
  # is-active бьёт по чужому юниту и может не заметить ЗАПУЩЕННЫЙ кластер, что
  # приведёт к перезаписи живого PGDATA. Пытаемся вывести версию из пути,
  # иначе берём умолчание, и подтверждаем у оператора.
  local pgver_default="$pgver"
  [[ "$restore_pgdata" =~ /pgpro/([^/]+)/ ]] && pgver_default="${BASH_REMATCH[1]}"
  pgver="$(prompt_default 'Версия PostgreSQL (PGVER)' "$pgver_default")"
  log_info "PGVER: ${BOLD}$pgver${NC}  →  юнит: ${BOLD}$(get_service_name "$pgver" "$pgport")${NC}"

  log_section "Точка восстановления"
  echo -e "${BOLD}Доступные бэкапы:${NC}"
  su - "$PG_SUPERUSER" -c "'${WALG_BIN}' backup-list --config '$walg_cfg'" 2>/dev/null \
    || log_warn "Не удалось получить список бэкапов."
  echo

  echo -e "${BOLD}Варианты восстановления:${NC}"
  echo -e "  ${CYAN}[1]${NC} LATEST (последний бэкап)"
  echo -e "  ${CYAN}[2]${NC} Указать имя бэкапа вручную"
  echo -e "  ${CYAN}[3]${NC} Восстановление до определённого времени (PITR)"
  echo

  local restore_choice backup_name="" pitr_target=""
  while true; do
    read -rp "Выберите вариант [1-3]: " restore_choice
    case "$restore_choice" in
      1) backup_name="LATEST"; break ;;
      2)
        backup_name="$(prompt_required 'Введите имя бэкапа')"
        break
        ;;
      3)
        pitr_target="$(prompt_required 'Введите дату/время (формат: YYYY-MM-DD HH:MM:SS [TZ])')"
        # Базовый бэкап должен быть СТАРШЕ целевого времени, иначе PostgreSQL
        # не сможет докатиться до точки восстановления.
        log_warn "Базовый бэкап должен быть сделан РАНЬШЕ целевого времени восстановления."
        backup_name="$(prompt_default 'Имя базового бэкапа' 'LATEST')"
        break
        ;;
      *) log_warn "Некорректный ввод." ;;
    esac
  done

  local service_name; service_name="$(get_service_name "$pgver" "$pgport")"

  log_section "Итоговые параметры"
  echo -e "  Порт:           ${BOLD}$pgport${NC}"
  echo -e "  PGDATA:         ${BOLD}$restore_pgdata${NC}"
  echo -e "  Сервис:         ${BOLD}$service_name${NC}"
  echo -e "  Конфиг WAL-G:   ${BOLD}$walg_cfg${NC}"
  echo -e "  Бэкап:          ${BOLD}$backup_name${NC}"
  [[ -n "$pitr_target" ]] && echo -e "  PITR до:        ${BOLD}$pitr_target${NC}"
  echo
  log_warn "Будет остановлен сервис (если запущен) и ЗАМЕНЕНЫ все данные в $restore_pgdata!"
  echo

  confirm_YES "Введите YES для подтверждения:" || { log_warn "Отменено пользователем."; return 0; }

  log_section "Подготовка"
  if systemctl is-active --quiet "$service_name" 2>/dev/null; then
    log_warn "Сервис ${BOLD}$service_name${NC} запущен!"
    if ask_yes_no "Остановить сервис перед восстановлением?"; then
      log_info "Останавливаю $service_name..."
      systemctl stop "$service_name"
      log_info "Сервис остановлен."
    else
      log_error "Восстановление невозможно при запущенном сервисе."
      return 1
    fi
  else
    log_info "Сервис $service_name не запущен. ОК"
  fi

  if [[ -d "$restore_pgdata" ]]; then
    log_warn "Директория ${BOLD}$restore_pgdata${NC} существует и будет ПЕРЕЗАПИСАНА!"
    local backup_old="${restore_pgdata}.bak.$(date +%Y%m%d_%H%M%S)"
    if ask_yes_no "Создать резервную копию текущего PGDATA?"; then
      log_info "Переименовываю в $backup_old ..."
      mv "$restore_pgdata" "$backup_old"
      log_info "Готово: $backup_old"
    else
      # Удаление без резервной копии — единственный безвозвратный шаг:
      # требуем отдельное явное подтверждение, иначе откатываемся к mv.
      log_warn "БЕЗВОЗВРАТНОЕ удаление ${BOLD}$restore_pgdata${NC} без резервной копии!"
      if confirm_YES "Введите YES для удаления без резервной копии:"; then
        log_warn "Удаляю $restore_pgdata ..."
        rm -rf "$restore_pgdata"
      else
        log_info "Не подтверждено — сохраняю текущий PGDATA в $backup_old."
        mv "$restore_pgdata" "$backup_old"
        log_info "Готово: $backup_old"
      fi
    fi
  fi

  mkdir -p "$restore_pgdata"
  chown postgres:postgres "$restore_pgdata"
  chmod 700 "$restore_pgdata"
  log_info "Директория подготовлена: $restore_pgdata"

  local log_dir="${restore_pgdata}/log"
  mkdir -p "$log_dir"
  chown postgres:postgres "$log_dir"
  local log_file="${log_dir}/wal-g-restore-${pgport}-$(date +%Y-%m-%d_%H-%M-%S).log"

  log_section "Запуск WAL-G backup-fetch"
  log_info "Лог: $log_file"

  su - "$PG_SUPERUSER" -c "'${WALG_BIN}' backup-fetch --config '$walg_cfg' '$restore_pgdata' '$backup_name'" \
    2>&1 | tee "$log_file"

  log_info "backup-fetch завершён."

  log_section "Настройка recovery"
  su - "$PG_SUPERUSER" -c "touch '$restore_pgdata/recovery.signal'"
  log_info "Создан recovery.signal"

  # restore_command нужен ВСЕГДА: без него PostgreSQL не сможет дотянуть WAL из
  # архива и не дойдёт до согласованного состояния (а PITR не сработает вовсе).
  local recovery_conf="$restore_pgdata/postgresql.auto.conf"
  local restore_cmd="${WALG_BIN} wal-fetch \"%f\" \"%p\" --config ${walg_cfg} >> ${log_dir}/restore_command.log 2>&1"

  log_info "Прописываю restore_command в $recovery_conf"
  cat >> "$recovery_conf" <<EOF

# --- WAL-G restore (добавлено $SELF_NAME $(date '+%F %T')) ---
restore_command = '${restore_cmd}'
EOF

  if [[ -n "$pitr_target" ]]; then
    log_info "Добавляю PITR-параметры (до $pitr_target)"
    cat >> "$recovery_conf" <<EOF
recovery_target_time = '${pitr_target}'
recovery_target_action = 'promote'
recovery_target_timeline = 'latest'
EOF
    log_info "PITR настроен до: $pitr_target"
  else
    log_info "Полное восстановление: WAL проигрывается до конца архива."
  fi

  chown -R postgres:postgres "$restore_pgdata"

  log_section "Запуск сервиса"
  if ask_yes_no "Запустить $service_name сейчас?"; then
    systemctl start "$service_name"
    sleep 3
    if systemctl is-active --quiet "$service_name"; then
      log_info "Сервис $service_name успешно запущен!"
    else
      log_error "Сервис не запустился. Проверьте логи:"
      echo "  journalctl -u $service_name -n 50"
      echo "  tail -n 50 $restore_pgdata/log/postgresql-*.log"
      return 1
    fi
  else
    log_info "Запустите сервис вручную: systemctl start $service_name"
  fi

  log_section "Восстановление завершено"
  log_info "Лог WAL-G: $log_file"
}

# ==============================================================================
# 7) УСТАНОВКА СКРИПТА И SYSTEMD-ЗАДАНИЯ (было wal-g-install.sh)
# ==============================================================================

INSTALL_DIR=""
ONCALENDAR=""

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

  def="${PGVER:-${def:-1c-18}}"

  if [[ -t 0 ]]; then
    local ans
    read -rp "Версия PostgreSQL (PGVER) [${def}]: " ans || ans=""
    def="${ans:-$def}"
  fi

  printf '%s\n' "$def"
}

current_install_dir() {
  local f="${SYSTEMD_DIR}/${UNIT_SERVICE}" line
  [[ -f "$f" ]] || return 1
  line="$(grep -m1 '^ExecStart=' "$f" 2>/dev/null)" || return 1
  line="${line#ExecStart=}"
  [[ -n "$line" ]] || return 1
  dirname "${line%% backup-all}"
}

current_oncalendar() {
  local f="${SYSTEMD_DIR}/${UNIT_TIMER}" line
  [[ -f "$f" ]] || return 1
  line="$(grep -m1 '^OnCalendar=' "$f" 2>/dev/null)" || return 1
  echo "${line#OnCalendar=}"
}

install_self() {
  install -d -m 755 "$INSTALL_DIR" || { log_error "Не удалось создать ${INSTALL_DIR}"; return 1; }

  local self_path; self_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
  local dst="${INSTALL_DIR}/${SELF_NAME}"

  if [[ "$(cd "$(dirname "$self_path")" && pwd -P)" == "$(cd "$INSTALL_DIR" && pwd -P)" ]]; then
    log_warn "Каталог установки совпадает с каталогом исходников — копирование пропущено."
    return 0
  fi

  install -m 755 "$self_path" "$dst" || { log_error "Не удалось скопировать скрипт в ${dst}"; return 1; }
  log_info "Скрипт установлен: ${dst}"
}

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
ExecStart=${INSTALL_DIR}/${SELF_NAME} backup-all
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
  log_info "  ExecStart   : ${INSTALL_DIR}/${SELF_NAME} backup-all"
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

action_install() {
  require_root
  log_section "Установка WAL-G-менеджера"

  local pgver; pgver="$(resolve_pgver)"

  INSTALL_DIR="$(prompt_default 'Каталог установки скрипта' "$DEFAULT_INSTALL_DIR")"
  ONCALENDAR="$(prompt_default 'Расписание бэкапа (OnCalendar)' "$DEFAULT_ONCALENDAR")"

  install_self || { log_error "Установка скрипта не удалась."; return 1; }
  install_units "$pgver"

  if ask_yes_no "Создать симлинк ${BIN_SYMLINK} → ${SELF_NAME}?"; then
    if ln -sfn "${INSTALL_DIR}/${SELF_NAME}" "$BIN_SYMLINK"; then
      log_info "Симлинк создан: ${BIN_SYMLINK}"
    else
      log_warn "Не удалось создать симлинк ${BIN_SYMLINK}"
    fi
  fi

  if command -v systemctl >/dev/null 2>&1; then
    if ask_yes_no "Включить и запустить таймер ${UNIT_TIMER} сейчас?"; then
      if systemctl enable --now "${UNIT_TIMER}"; then
        log_info "Таймер включён."
      else
        log_warn "Не удалось включить таймер."
      fi
    fi
  fi

  log_section "Установка завершена"
  log_info "Запуск: ${INSTALL_DIR}/${SELF_NAME}"
  [[ -L "$BIN_SYMLINK" ]] && log_info "   или: wal-g-manager"
}

action_units_only() {
  require_root
  INSTALL_DIR="$(current_install_dir 2>/dev/null || echo "$DEFAULT_INSTALL_DIR")"
  ONCALENDAR="$(current_oncalendar 2>/dev/null || echo "$DEFAULT_ONCALENDAR")"
  local pgver; pgver="$(resolve_pgver)"
  install_units "$pgver"
}

action_uninstall() {
  require_root
  log_section "Удаление WAL-G-менеджера"
  uninstall_units

  local dir; dir="$(current_install_dir 2>/dev/null || true)"
  dir="${dir:-$DEFAULT_INSTALL_DIR}"

  if ask_yes_no "Удалить установленную копию скрипта из ${dir}?"; then
    rm -f "${dir}/${SELF_NAME}"
    rmdir "${dir}" 2>/dev/null || true
    log_info "Скрипт удалён из ${dir}"
  fi

  [[ -L "$BIN_SYMLINK" ]] && { rm -f "$BIN_SYMLINK"; log_info "Симлинк ${BIN_SYMLINK} удалён."; }
  log_section "Удаление завершено"
}

systemd_status() {
  log_section "Статус задания резервного копирования"

  if ! command -v systemctl >/dev/null 2>&1; then
    log_warn "systemctl недоступен в этой системе."
    return 0
  fi

  local svc_file="${SYSTEMD_DIR}/${UNIT_SERVICE}" tmr_file="${SYSTEMD_DIR}/${UNIT_TIMER}"

  if [[ -f "$tmr_file" || -f "$svc_file" ]]; then
    log_info "Файлы юнитов: $( [[ -f "$svc_file" ]] && echo "${UNIT_SERVICE} ✓" || echo "${UNIT_SERVICE} ✗" ), $( [[ -f "$tmr_file" ]] && echo "${UNIT_TIMER} ✓" || echo "${UNIT_TIMER} ✗" )"
  else
    log_warn "Юниты не установлены (нет файлов в ${SYSTEMD_DIR})."
    return 0
  fi

  echo -e "  enabled : ${BOLD}$(systemctl is-enabled "${UNIT_TIMER}" 2>/dev/null || echo '—')${NC}"
  echo -e "  active  : ${BOLD}$(systemctl is-active  "${UNIT_TIMER}" 2>/dev/null || echo '—')${NC}"
  echo
  systemctl list-timers --all "${UNIT_TIMER}" --no-pager 2>/dev/null || true
}

menu_systemd() {
  while true; do
    echo
    echo -e "${BOLD}--- Задание systemd (резервное копирование) ---${NC}"
    echo -e "  ${BOLD}1.${NC} Показать статус"
    echo -e "  ${BOLD}2.${NC} Установить/обновить юниты и включить"
    echo -e "  ${BOLD}3.${NC} Отключить (disable --now)"
    echo -e "  ${BOLD}4.${NC} Удалить юниты"
    echo -e "  ${BOLD}0.${NC} Назад"
    echo
    local c; read -rp "Выберите пункт [0-4]: " c || { echo; return 0; }
    case "$c" in
      1) systemd_status; pause ;;
      2)
        action_units_only
        if command -v systemctl >/dev/null 2>&1; then
          systemctl enable --now "${UNIT_TIMER}" \
            && log_info "Таймер ${UNIT_TIMER} включён." \
            || log_warn "Не удалось включить таймер ${UNIT_TIMER}."
        fi
        pause
        ;;
      3)
        if command -v systemctl >/dev/null 2>&1; then
          systemctl disable --now "${UNIT_TIMER}" && log_info "Таймер отключён." \
            || log_warn "Не удалось отключить таймер."
        else
          log_warn "systemctl недоступен."
        fi
        pause
        ;;
      4)
        if ask_yes_no "Удалить юниты ${UNIT_TIMER}/${UNIT_SERVICE}?"; then
          uninstall_units
        else
          log_info "Отменено."
        fi
        pause
        ;;
      0|q|Q) return 0 ;;
      *) log_warn "Некорректный ввод: '${c}'." ;;
    esac
  done
}

# ==============================================================================
# ГЛАВНОЕ МЕНЮ
# ==============================================================================

pause() {
  echo
  read -rsp "Нажмите Enter для возврата в меню..." _ || true
  echo
}

print_main_menu() {
  echo
  echo -e "${BOLD}============================================================${NC}"
  echo -e "${BOLD}             WAL-G — панель управления${NC}"
  echo -e "${BOLD}============================================================${NC}"
  echo
  echo -e "  ${BOLD}1.${NC} Настройка WAL-G           — создать/обновить конфиги и параметры архивации"
  echo -e "  ${BOLD}2.${NC} Список бэкапов            — показать доступные бэкапы по кластерам"
  echo -e "  ${BOLD}3.${NC} Создать бэкап             — интерактивный delta/FULL-бэкап выбранных кластеров"
  echo -e "  ${BOLD}4.${NC} Бэкап всех кластеров      — неинтерактивный прогон (как в systemd-таймере) + retain"
  echo -e "  ${BOLD}5.${NC} Удалить бэкапы            — удаление старых бэкапов (retain FULL N)"
  echo -e "  ${BOLD}6.${NC} Восстановление            — восстановление кластера из бэкапа (в т.ч. PITR)"
  echo -e "  ${BOLD}7.${NC} Задание systemd           — просмотр/включение/удаление таймера бэкапа"
  echo -e "  ${BOLD}8.${NC} Установка/обновление      — развернуть скрипт и systemd-юниты"
  echo
  echo -e "  ${BOLD}0.${NC} Выход"
  echo
}

main_menu() {
  if [[ ! -t 0 ]]; then
    log_error "Нужен интерактивный терминал (stdin не является TTY)."
    exit 1
  fi
  trap 'echo; log_warn "Прервано пользователем."' INT

  while true; do
    print_main_menu
    local choice; read -rp "Выберите пункт [0-8]: " choice || { echo; exit 0; }
    case "$choice" in
      0|q|Q|exit) echo "Выход."; exit 0 ;;
      1) action_configure; pause ;;
      2) action_list; pause ;;
      3) action_backup; pause ;;
      4) action_backup_all; pause ;;
      5) action_delete; pause ;;
      6) action_restore; pause ;;
      7) menu_systemd ;;
      8) action_install; pause ;;
      *) log_warn "Некорректный ввод: '${choice}'. Введите число из меню." ;;
    esac
  done
}

usage() {
  sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ==============================================================================
# ТОЧКА ВХОДА
# ==============================================================================

CMD="${1:-menu}"
[[ $# -gt 0 ]] && shift

case "$CMD" in
  menu)              require_root; main_menu ;;
  cfg)                action_configure ;;
  list)               action_list "$@" ;;
  backup)             action_backup ;;
  backup-all)         action_backup_all ;;
  delete)             action_delete ;;
  restore)            action_restore ;;
  install)            action_install ;;
  units)              action_units_only ;;
  uninstall-units)    require_root; uninstall_units ;;
  uninstall)          action_uninstall ;;
  -h|--help|help)     usage ;;
  *)
    log_error "Неизвестная команда: ${CMD}"
    usage
    exit 1
    ;;
esac
