#!/usr/bin/env bash

# Скрипт для настройки конфигурационных файлов WAL-G для хранилища S3 или файлового варианта
# Скрипт автоматически определяет кластера PostgreSQL и каталоги данных
# Также автоматически добавляются необходимые параметры для архивации в postgresql.auto.conf
# Для корректной работы скрипта должен быть настроен файл паролей .pgpass
#
# Запускать от root: требуется создание /etc/wal-g.d, chown postgres и systemctl restart.
# Сокет PostgreSQL берётся из PGHOST_SOCKET (по умолчанию /tmp — конвенция PostgresPro 1C).

set -Eeuo pipefail

# Диагностика непредвиденных ошибок (флаг -E делает трап ERR наследуемым функциями).
trap 'rc=$?; echo "ERROR: команда «${BASH_COMMAND}» завершилась с кодом ${rc} (строка ${LINENO})" >&2' ERR

# =============================================================================
# КОНСТАНТЫ
# =============================================================================

WALG_DIR='/etc/wal-g.d'
WALG_COMPRESSION_METHOD='brotli'
PGHOST_SOCKET='/tmp'          # каталог unix-сокета PostgreSQL
PG_SUPERUSER='postgres'

# Конфиги содержат секреты: umask 077 закрывает окно world-readable между
# созданием файла и chmod 600 (install -d ниже задаёт режим каталога явно).
umask 077

# Кэш PGDATA: заполняется при обзоре кластеров, переиспользуется в шаге 7.
declare -A CLUSTER_PGDATA=()

# =============================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# =============================================================================

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
    [[ -z "$var" ]] && echo "Значение обязательно" >&2
  done
  echo "$var"
}

# Единый y/N-вопрос: принимает y, Y, yes, YES.
ask_yes_no() {
  local prompt="$1" ans
  read -r -p "${prompt} [y/N]: " ans || return 1
  [[ "$ans" =~ ^([yY]|[yY][eE][sS])$ ]]
}

# Экранирование строки для безопасной вставки в JSON-значение.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"   # обратный слэш — первым
  s="${s//\"/\\\"}"   # затем двойная кавычка
  printf '%s' "$s"
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

# =============================================================================
# ИМЯ СЕРВИСА SYSTEMD
# =============================================================================

get_service_name() {
  local pgver="$1"
  local pgport="$2"
  if [[ "$pgport" == "5432" ]]; then
    echo "postgrespro-${pgver}.service"
  else
    echo "postgrespro-${pgver}@${pgport}.service"
  fi
}

# =============================================================================
# ПЕРЕЗАПУСК СЕРВИСА
# =============================================================================

restart_pg_service() {
  local pgver="$1"
  local pgport="$2"
  local svc
  svc="$(get_service_name "$pgver" "$pgport")"

  echo
  echo "INFO: имя сервиса ${svc}"

  if ! ask_yes_no "Перезапустить сервис ${svc}?"; then
    echo "INFO: перезапуск отменён. Выполните вручную:"
    echo "      systemctl restart ${svc}"
    return 0
  fi

  echo "INFO: выполняется systemctl restart ${svc} ..."

  if ! systemctl restart "$svc"; then
    echo "ERROR: не удалось перезапустить сервис ${svc}" >&2
    echo "INFO: проверьте статус: systemctl status ${svc}" >&2
    return 1
  fi

  # Ждём готовности кластера после перезапуска
  local retries=10 i=1
  echo "INFO: ожидание готовности кластера на порту ${pgport}..."
  while (( i <= retries )); do
    if pg_alive "$pgport" 2; then
      echo "OK: кластер ${pgport} запущен."
      return 0
    fi
    echo "  попытка ${i}/${retries}..."
    sleep 2
    i=$(( i + 1 ))
  done

  echo "WARN: кластер ${pgport} не ответил после ${retries} попыток." >&2
  echo "INFO: проверьте статус: systemctl status ${svc}" >&2
  return 1
}

# =============================================================================
# ВЫВОД СПИСКА КЛАСТЕРОВ
# =============================================================================

print_cluster_summary() {
  local -a ports=("$@")
  local port pgdata cfg_path cfg_info avail_status backend_info pgdata_info idx=1

  echo
  echo "=== Доступные кластеры ==="
  echo

  for port in "${ports[@]}"; do
    cfg_path="${WALG_DIR}/.walg-${port}.json"

    # Доступность и PGDATA
    if pg_alive "$port"; then
      avail_status="OK"
      pgdata="$(pg_show "$port" data_directory)" || pgdata=""
      [[ -n "$pgdata" ]] && CLUSTER_PGDATA["$port"]="$pgdata"
    else
      avail_status="!!"
      pgdata=""
    fi

    # Статус конфига и тип хранилища
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

    # PGDATA
    if [[ -n "$pgdata" ]]; then
      pgdata_info="PGDATA=${pgdata}"
    else
      pgdata_info="PGDATA недоступен"
    fi

    printf "  %2d. [ %s ] Порт %-5s  |  %s, %s\n" \
      "$idx" "$avail_status" "$port" "$pgdata_info" "$cfg_info"

    idx=$(( idx + 1 ))
  done

  echo
  printf "   0. Выход\n"
  echo
}

# =============================================================================
# ВЫБОР ПОРТОВ ПО НОМЕРАМ ИЗ СПИСКА
# =============================================================================

select_ports_by_index() {
  local -n _ports_ref="$1"
  local total="${#_ports_ref[@]}"
  local input sel port result=()

  while true; do
    read -r -p "Введите номера через пробел или 'all' для всех [all]: " input
    input="${input:-all}"

    if [[ "$input" == "0" ]]; then
      echo "Выход." >&2
      exit 0
    fi

    if [[ "$input" == "all" ]]; then
      SELECTED_PORTS=("${_ports_ref[@]}")
      return
    fi

    result=()
    local valid=1

    for sel in $input; do
      if ! [[ "$sel" =~ ^[0-9]+$ ]]; then
        echo "WARN: '${sel}' не является числом, повторите ввод." >&2
        valid=0
        break
      fi
      if (( sel < 1 || sel > total )); then
        echo "WARN: номер ${sel} вне диапазона 1–${total}, повторите ввод." >&2
        valid=0
        break
      fi
      port="${_ports_ref[$(( sel - 1 ))]}"
      result+=("$port")
    done

    if (( valid )) && (( ${#result[@]} > 0 )); then
      SELECTED_PORTS=("${result[@]}")
      return
    fi
  done
}

# =============================================================================
# НАСТРОЙКА ПАРАМЕТРОВ POSTGRESQL ДЛЯ АРХИВАЦИИ
# =============================================================================

configure_pg_instance() {
  local pgport="$1"
  local pgdata="$2"
  local walgcfg="$3"

  local -a PSQL=(
    psql -h "$PGHOST_SOCKET" -p "$pgport" -U "$PG_SUPERUSER" -d postgres
    -At -q -X -v ON_ERROR_STOP=1
  )

  local logdir
  logdir="$("${PSQL[@]}" -c "SHOW log_directory;" 2>/dev/null)" || {
    echo "ERROR: не удалось получить log_directory для ${pgport}" >&2
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
    [archive_command]="/usr/bin/wal-g wal-push \"%p\" --config ${walgcfg} >> ${pglogdir}/archive_command.log 2>&1"
    [restore_command]="/usr/bin/wal-g wal-fetch \"%f\" \"%p\" --config ${walgcfg} >> ${pglogdir}/restore_command.log 2>&1"
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
    echo "ERROR: не удалось получить параметры pg_settings для ${pgport}" >&2
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
      echo "ERROR: параметр '${p}' не получен из pg_settings" >&2
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
    echo "INFO: параметры PostgreSQL ${pgport} уже соответствуют целевым."
    PG_RESTART_NEEDED=0
    return 0
  fi

  echo
  echo "=== Параметры PostgreSQL (${pgport}) ==="
  for p in "${PARAMS[@]}"; do
    local cur="${CUR[$p]}"
    local want="${WANT[$p]}"
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
    echo "INFO: изменения ${pgport} отменены пользователем."
    PG_RESTART_NEEDED=0
    return 0
  fi

  # Все ALTER SYSTEM применяем одним вызовом psql (ON_ERROR_STOP=1 — атомарно).
  local sql=""
  for p in "${TO_CHANGE[@]}"; do
    local esc="${WANT[$p]//\'/\'\'}"
    sql+="ALTER SYSTEM SET ${p} = '${esc}';"$'\n'
  done

  if ! "${PSQL[@]}" -c "$sql" >/dev/null; then
    echo "ERROR: не удалось применить параметры PostgreSQL ${pgport}" >&2
    return 1
  fi
  for p in "${TO_CHANGE[@]}"; do
    echo "  SET ${p}"
  done

  if ! "${PSQL[@]}" -c "SELECT pg_reload_conf();" >/dev/null 2>&1; then
    echo "WARN: не удалось выполнить pg_reload_conf() ${pgport}" >&2
  fi

  # Возвращаем признак необходимости перезапуска через глобальную переменную
  if (( restart_needed )); then
    echo "INFO: параметры wal_level/archive_mode требуют перезапуска сервиса."
    PG_RESTART_NEEDED=1
  else
    echo "OK: параметры обновлены без необходимости перезапуска."
    PG_RESTART_NEEDED=0
  fi
}

# =============================================================================
# ШАГ 1: ОБНАРУЖЕНИЕ И ВЫВОД СПИСКА КЛАСТЕРОВ
# =============================================================================

FOUND_PORTS=()
if command -v ss >/dev/null 2>&1; then
  mapfile -t FOUND_PORTS < <(ss -tlnp 2>/dev/null \
    | grep postgres \
    | grep -oP ':\K\d+' \
    | sort -un)
fi

SELECTED_PORTS=()
if (( ${#FOUND_PORTS[@]} > 0 )); then
  print_cluster_summary "${FOUND_PORTS[@]}"
  select_ports_by_index FOUND_PORTS
else
  echo "WARN: кластеры не обнаружены автоматически (нужны права root для ss -p)." >&2
  MANUAL="$(prompt_required 'Укажите порты через пробел (например: 5432 5433)')"
  read -r -a SELECTED_PORTS <<< "$MANUAL"
fi

if (( ${#SELECTED_PORTS[@]} == 0 )); then
  echo "ERROR: список пуст — нечего настраивать" >&2
  exit 1
fi

echo
echo "Выбраны порты: ${SELECTED_PORTS[*]}"
echo

# =============================================================================
# ШАГ 2: ТИП ХРАНИЛИЩА
# =============================================================================

echo "Тип хранилища:"
echo "  1. S3"
echo "  2. Файловое"
echo "  0. Выход"
echo
while true; do
  read -r -p "Выбор [1]: " BACKEND_SEL
  BACKEND_SEL="${BACKEND_SEL:-1}"
  case "${BACKEND_SEL}" in
    1) BACKEND="s3";   break ;;
    2) BACKEND="file"; break ;;
    0) echo "Выход."; exit 0 ;;
    *) echo "WARN: введите 0, 1 или 2." >&2 ;;
  esac
done

echo "INFO: тип хранилища = ${BACKEND}"
echo

# =============================================================================
# ШАГ 3: ВЕРСИЯ POSTGRESQL
# =============================================================================

PGVER="$(prompt_default 'Версия PostgreSQL (PGVER)' '1c-18')"

# =============================================================================
# ШАГ 4: WALG_DELTA_MAX_STEPS
# =============================================================================

WALG_DELTA_MAX_STEPS="$(prompt_default 'WALG_DELTA_MAX_STEPS' '6')"
if ! [[ "$WALG_DELTA_MAX_STEPS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: WALG_DELTA_MAX_STEPS должен быть целым числом" >&2
  exit 1
fi

# =============================================================================
# ШАГ 5: ПАРАМЕТРЫ БЭКЕНДА
# =============================================================================

if [[ "$BACKEND" == "s3" ]]; then
  AWS_ENDPOINT="$(prompt_default     'AWS_ENDPOINT'        's3.ru-3.storage.selcloud.ru:443')"
  AWS_REGION="$(prompt_default       'AWS_REGION'          'ru-3')"
  AWS_ACCESS_KEY_ID="$(prompt_required     'AWS_ACCESS_KEY_ID')"
  AWS_SECRET_ACCESS_KEY="$(prompt_required 'AWS_SECRET_ACCESS_KEY')"
  S3_BUCKET="$(prompt_required             'S3_BUCKET')"

  [[ "$S3_BUCKET" != s3://* ]] && S3_BUCKET="s3://${S3_BUCKET}"
  S3_BUCKET="${S3_BUCKET%/}"

  # Экранируем значения один раз для безопасной вставки в JSON
  J_AWS_ENDPOINT="$(json_escape "$AWS_ENDPOINT")"
  J_AWS_REGION="$(json_escape "$AWS_REGION")"
  J_AWS_ACCESS_KEY_ID="$(json_escape "$AWS_ACCESS_KEY_ID")"
  J_AWS_SECRET_ACCESS_KEY="$(json_escape "$AWS_SECRET_ACCESS_KEY")"
  J_S3_BUCKET="$(json_escape "$S3_BUCKET")"
else
  WALG_FILE_PREFIX_BASE="$(prompt_default 'Базовый каталог WALG_FILE_PREFIX' '/backup')"
  WALG_FILE_PREFIX_BASE="${WALG_FILE_PREFIX_BASE%/}"
  J_WALG_FILE_PREFIX_BASE="$(json_escape "$WALG_FILE_PREFIX_BASE")"
fi

# =============================================================================
# ШАГ 6: ПОДГОТОВКА КАТАЛОГА
# =============================================================================

if ! install -d -m 755 "$WALG_DIR" 2>/dev/null; then
  echo "ERROR: нет прав на создание каталога ${WALG_DIR}" >&2
  exit 1
fi

# =============================================================================
# ШАГ 7: ОБРАБОТКА КАЖДОГО КЛАСТЕРА
# =============================================================================

for PGPORT in "${SELECTED_PORTS[@]}"; do

  echo
  echo "━━━ Порт ${PGPORT} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if ! [[ "$PGPORT" =~ ^[0-9]+$ ]]; then
    echo "WARN: некорректный номер '${PGPORT}', пропуск" >&2
    continue
  fi

  SVC_NAME="$(get_service_name "$PGVER" "$PGPORT")"
  echo "INFO: сервис systemd: ${SVC_NAME}"

  CFG="${WALG_DIR}/.walg-${PGPORT}.json"

  if ! pg_alive "$PGPORT"; then
    echo "WARN: кластер на порту ${PGPORT} недоступен, пропуск" >&2
    continue
  fi

  # PGDATA берём из кэша обзора, иначе запрашиваем у кластера.
  if [[ -n "${CLUSTER_PGDATA[$PGPORT]+x}" ]]; then
    PGDATA="${CLUSTER_PGDATA[$PGPORT]}"
  else
    PGDATA="$(pg_show "$PGPORT" data_directory)" || PGDATA=""
  fi

  if [[ -z "$PGDATA" || ! -d "$PGDATA" ]]; then
    echo "WARN: не удалось определить PGDATA для порта ${PGPORT}, пропуск" >&2
    continue
  fi

  echo "INFO: PGDATA = ${PGDATA}"

  # --- Решаем, нужно ли (пере)записывать конфиг ---
  WRITE_CFG=1
  if [[ -f "$CFG" ]]; then
    if ask_yes_no "Файл ${CFG} уже существует. Перезаписать?"; then
      if ! cp -p -- "$CFG" "${CFG}.bak"; then
        echo "ERROR: не удалось создать резервную копию ${CFG}.bak, пропуск" >&2
        continue
      fi
      echo "INFO: создана резервная копия ${CFG}.bak"
    else
      echo "INFO: конфиг ${CFG} оставлен без изменений."
      WRITE_CFG=0
    fi
  fi

  # --- Запись конфига (umask 077 уже гарантирует режим 600 при создании) ---
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
    if ! chown postgres:postgres "$CFG" 2>/dev/null; then
      echo "WARN: не удалось установить владельца postgres для ${CFG}" >&2
    fi
    echo "OK: конфиг записан: ${CFG}"
  fi

  # --- Настройка параметров PostgreSQL (вызов защищён: сбой не прерывает цикл) ---
  PG_RESTART_NEEDED=0
  if configure_pg_instance "$PGPORT" "$PGDATA" "$CFG"; then
    if (( PG_RESTART_NEEDED )); then
      restart_pg_service "$PGVER" "$PGPORT" \
        || echo "WARN: перезапуск ${PGPORT} не выполнен, перехожу к следующему кластеру." >&2
    fi
  else
    echo "WARN: настройка параметров PostgreSQL ${PGPORT} не завершена, пропуск." >&2
  fi

done

echo
echo "Готово."
