#!/bin/bash
# Тест дисков NVMe (профиль CrystalDiskMark: SEQ1M Q8T1, SEQ128K Q32T1, RND4K Q32T8, RND4K Q1T1)
# Парсинг через JSON-вывод fio + jq, все значения в MB/s (десятичные, как у fio/CDM)
set -u
set -o pipefail

# --- Проверка зависимостей ---------------------------------------------------
for cmd in fio jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Ошибка: '$cmd' не найден (команда отсутствует в PATH)."
    echo "Debian/Ubuntu: sudo apt install -y $cmd"
    exit 127
  fi
done

# --- Параметры ----------------------------------------------------------------
TESTFILE_PATH='/980PRO/fiotest.tmp'
TESTFILE_SIZE='1000m'
TEST_LOOPS='5'

# --- Проверка каталога ---------------------------------------------------------
TESTDIR=$(dirname "$TESTFILE_PATH")
if [ ! -d "$TESTDIR" ] || [ ! -w "$TESTDIR" ]; then
  echo "Ошибка: каталог '$TESTDIR' не существует или недоступен для записи."
  exit 1
fi

# --- Уборка тестового файла при любом выходе -----------------------------------
trap 'rm -f "$TESTFILE_PATH"' EXIT

FIO_BASE=(fio
  --loops="$TEST_LOOPS"
  --size="$TESTFILE_SIZE"
  --filename="$TESTFILE_PATH"
  --ioengine=libaio
  --direct=1
  --group_reporting
  --output-format=json
)

pause_io() { sync; sleep 3; }

# run_test <read|write> <доп. параметры fio...>
# Возвращает скорость в MB/s (десятичных, bw_bytes/1e6) или "ERR" при сбое.
run_test() {
  local direction="$1"; shift
  local json bw
  if ! json=$("${FIO_BASE[@]}" "$@" 2>/dev/null); then
    echo "ERR"; return 1
  fi
  bw=$(jq -r --arg d "$direction" '.jobs[0][$d].bw_bytes' <<<"$json" 2>/dev/null)
  if [ -z "$bw" ] || [ "$bw" = "null" ]; then
    echo "ERR"; return 1
  fi
  awk -v b="$bw" 'BEGIN { printf "%.1f", b / 1000000 }'
}

print_header() {
  echo " +------------------------------------------------+"
  printf " | %12s | %14s | %14s |\n" "Mode" "Read, MB/s" "Write, MB/s"
  echo " +------------------------------------------------+"
}
print_row() {
  printf " | %12s | %14s | %14s |\n" "$1" "$2" "$3"
  echo " +------------------------------------------------+"
}

# --- Тесты ---------------------------------------------------------------------
pause_io
SEQ1MQ8T1R=$(run_test read  --name=SeqReadQ8  --bs=1m --iodepth=8 --rw=read)
pause_io
SEQ1MQ8T1W=$(run_test write --name=SeqWriteQ8 --bs=1m --iodepth=8 --rw=write)
print_header
print_row "SEQ1MQ8T1" "$SEQ1MQ8T1R" "$SEQ1MQ8T1W"

pause_io
SEQ128KQ32T1R=$(run_test read  --name=SeqReadQ32  --bs=128k --iodepth=32 --rw=read)
pause_io
SEQ128KQ32T1W=$(run_test write --name=SeqWriteQ32 --bs=128k --iodepth=32 --rw=write)
print_row "SEQ128KQ32T1" "$SEQ128KQ32T1R" "$SEQ128KQ32T1W"

pause_io
RND4KQ32T8R=$(run_test read  --name=RandReadQ32  --bs=4k --iodepth=32 --numjobs=8 --rw=randread)
pause_io
RND4KQ32T8W=$(run_test write --name=RandWriteQ32 --bs=4k --iodepth=32 --numjobs=8 --rw=randwrite)
print_row "RND4KQ32T8" "$RND4KQ32T8R" "$RND4KQ32T8W"

pause_io
RND4KQ1T1R=$(run_test read  --name=RandReadQ1  --bs=4k --iodepth=1 --rw=randread)
pause_io
RND4KQ1T1W=$(run_test write --name=RandWriteQ1 --bs=4k --iodepth=1 --rw=randwrite)
print_row "RND4KQ1T1" "$RND4KQ1T1R" "$RND4KQ1T1W"
