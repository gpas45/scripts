#!/bin/bash
# Тест дисков NVMe

set -u
set -o pipefail

# Проверка: установлен ли fio
if ! command -v fio >/dev/null 2>&1; then
  echo "Ошибка: 'fio' не найден (команда отсутствует в PATH). Установите fio и повторите."
  echo "Debian/Ubuntu: sudo apt install -y fio"
  exit 127
fi

TESTFILE_PATH='/980PRO/fiotest.tmp'
TESTFILE_SIZE='1000m'
TEST_LOOPS='5'

FIO_BASE=(fio
  --loops="$TEST_LOOPS"
  --size="$TESTFILE_SIZE"
  --filename="$TESTFILE_PATH"
  --ioengine=libaio
  --direct=1
)

pause_io() { sync; sleep 3; }

# Оставляем исходную логику парсинга: 3-е поле и вырезаем "bw=...MiB/s"
# (как было: substr($3, 2, length($3)-3))
extract_bw() {
  grep -E "$1" | awk '{print substr($3, 2, length($3)-3)}'
}

print_header() {
  echo " +----------------------------------------+"
  printf " | %12s | %10s | %10s |\n" "Mode" "Read" "Write"
  echo " +----------------------------------------+"
}
print_row() {
  printf " | %12s | %10s | %10s |\n" "$1" "$2" "$3"
  echo " +----------------------------------------+"
}

pause_io
SEQ1MQ8T1R=$("${FIO_BASE[@]}" --name=SeqReadQ8  --bs=1m   --iodepth=8  --rw=read  | extract_bw 'READ:')
pause_io
SEQ1MQ8T1W=$("${FIO_BASE[@]}" --name=SeqWriteQ8 --bs=1m   --iodepth=8  --rw=write | extract_bw 'WRITE:')

print_header
print_row "SEQ1MQ8T1" "$SEQ1MQ8T1R" "$SEQ1MQ8T1W"

pause_io
SEQ128KQ32T1R=$("${FIO_BASE[@]}" --name=SeqReadQ32  --bs=128k --iodepth=32 --rw=read  | extract_bw 'READ:')
pause_io
SEQ128KQ32T1W=$("${FIO_BASE[@]}" --name=SeqWriteQ32 --bs=128k --iodepth=32 --rw=write | extract_bw 'WRITE:')
print_row "SEQ128KQ32T1" "$SEQ128KQ32T1R" "$SEQ128KQ32T1W"

pause_io
RND4KQ32T8R=$("${FIO_BASE[@]}" --name=RandReadQ32  --bs=4k --iodepth=32 --numjobs=8 --rw=randread  | extract_bw 'READ:')
pause_io
RND4KQ32T8W=$("${FIO_BASE[@]}" --name=RandWriteQ32 --bs=4k --iodepth=32 --numjobs=8 --rw=randwrite | extract_bw 'WRITE:')
print_row "RND4KQ32T8" "$RND4KQ32T8R" "$RND4KQ32T8W"

pause_io
RND4KQ1T1R=$("${FIO_BASE[@]}" --name=RandReadQ1  --bs=4k --iodepth=1 --rw=randread  | extract_bw 'READ:')
pause_io
RND4KQ1T1W=$("${FIO_BASE[@]}" --name=RandWriteQ1 --bs=4k --iodepth=1 --rw=randwrite | extract_bw 'WRITE:')
print_row "RND4KQ1T1" "$RND4KQ1T1R" "$RND4KQ1T1W"
