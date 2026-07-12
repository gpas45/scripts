#!/bin/bash
#
# pgpro-diag.sh — диагностика шаблонных экземпляров Postgres Pro 1C.
# Собирает в один файл всё, что нужно, чтобы подстроить pg-server-manager.sh
# под штатную шаблонную схему postgrespro-<ver>@<порт>.
#
# Запуск:  ./pgpro-diag.sh            # релиз по умолчанию 1c-18
#          ./pgpro-diag.sh 1c-17      # другой релиз
# Результат: /root/pgpro-diag-<ver>.txt
#
VER="${1:-1c-18}"
OUT="/root/pgpro-diag-${VER}.txt"

# первый существующий @-экземпляр как образец
SAMPLE=$(systemctl list-units --all --type=service "postgrespro-${VER}@*" --no-legend --no-pager 2>/dev/null \
         | awk '{print $1}' | sed 's/\.service$//' | head -n1)

{
  echo "############ Postgres Pro diag: ver=${VER} sample=${SAMPLE:-<нет>} $(date) ############"

  echo; echo "=== 1. шаблонный юнит ==="
  systemctl cat "postgrespro-${VER}@.service" 2>&1

  if [[ -n "$SAMPLE" ]]; then
    echo; echo "=== 2. полный конфиг экземпляра ${SAMPLE} (шаблон + drop-in) ==="
    systemctl cat "${SAMPLE}.service" 2>&1
    echo; echo "=== 3. drop-in каталог ${SAMPLE} ==="
    ls -la "/etc/systemd/system/${SAMPLE}.service.d/" 2>&1
    echo; echo "=== 3b. содержимое drop-in файлов ==="
    for f in "/etc/systemd/system/${SAMPLE}.service.d/"*.conf; do
      [[ -e "$f" ]] || continue
      echo "--- $f ---"; cat "$f" 2>&1
    done
    echo; echo "=== 4. resolved Environment/ExecStart/EnvironmentFiles ${SAMPLE} ==="
    systemctl show "${SAMPLE}" -p Environment -p EnvironmentFiles -p ExecStart -p ExecStartPre -p FragmentPath -p DropInPaths --no-pager 2>&1
    echo; echo "=== 4b. реальный -D из работающего процесса ==="
    pid=$(systemctl show "${SAMPLE}" -p MainPID --value 2>/dev/null)
    if [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 ]]; then
      tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null; echo
    else echo "процесс не запущен (MainPID=$pid)"; fi
  fi

  echo; echo "=== 5. per-instance файлы в /etc/default ==="
  for f in /etc/default/*postgrespro*; do
    [[ -e "$f" ]] && ls -la "$f"
  done
  echo; echo "=== 5b. общий EnvironmentFile /etc/default/postgrespro-${VER} ==="
  cat "/etc/default/postgrespro-${VER}" 2>&1

  echo; echo "=== 6. все @-экземпляры (active/enabled) ==="
  systemctl list-units --all --type=service "postgrespro-${VER}@*" --no-legend --no-pager 2>&1 | awk '{print $1, $3, $4}'
  echo "--- enabled-симлинки ---"
  ls -la /etc/systemd/system/*.wants/postgrespro-"${VER}"@*.service 2>&1

  echo; echo "=== 7. каталоги данных /var/lib/pgpro/${VER} ==="
  ls -la "/var/lib/pgpro/${VER}/" 2>&1

  echo; echo "=== 8. содержимое scripts/ ==="
  ls -la "/var/lib/pgpro/${VER}/scripts/" 2>&1

  echo; echo "############ конец ############"
} > "$OUT" 2>&1

echo "Готово. Пришли файл: $OUT"
