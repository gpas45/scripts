#!/bin/bash
PATH=/sbin:/bin:/usr/sbin:/usr/bin

#Скрипт для бэкапа и обслуживания баз данных PostgreSQL


#Базы для бэкапа
BASES="/var/lib/pgpro/scripts/DB"

#Переменная даты и времени
DATA="$(date +%Y-%m-%d_%H-%M)"

#Директория для логов
LOGS=/var/lib/pgpro/service_logs

#Директория для бэкапов
BACKUPDIR=/var/lib/backup/pgpro

#Минимальное количество бэкапов
FILEBACK="28"


CheckDir()
{
	if touch "$1"/"$2".test > /dev/null 2>&1 ; then
		rm "$1"/"$2".test
		return 0
	else
		echo "$(date +%Y-%m-%d_%H-%M-%S)" "Ошибка создания файла, нет директории "$1" или отсутвуют права"
		return 1
	fi
}


CheckDB()
{
	if [[ ! -f "$1" ]]; then
		echo "$(date +%Y-%m-%d_%H-%M-%S)" "Ошибка, файл со списком БД для резервного копирования "$1" не найден." >> $LOGS/$DATA.log
		exit
	else
		return 0
	fi
}


Backup()
{
	CheckDir "$BACKUPDIR" "$DATA"
	CheckDB "$BASES"
	echo "$(date +%Y-%m-%d_%H-%M-%S)" "Старт резервного копирования" "$1" >> "$LOGS"/"$DATA".log
	sudo -u postgres /usr/bin/pg_dump -U postgres "$1" | pigz > "$BACKUPDIR"/"$DATA"-"$1".sql.gz 2>>"$LOGS"/"$DATA".log
        if [[  $? -eq 0 ]]; then
                echo "$(date +%Y-%m-%d_%H-%M-%S)" "Резервное копирование закончено" "$1" >> "$LOGS"/"$DATA".log
                return 0
      	else
                echo "$(date +%Y-%m-%d_%H-%M-%S)" "Ошибка создания резервной копии" "$1" >> "$LOGS"/"$DATA".log
                return 1
      	fi
}


ClearOldFiles()
{
	local FILES
	local NUM="1"
	FILES=$(find "$BACKUPDIR" -maxdepth 1 -type f -name "*-""$1""sql.gz" | wc -l)
	if [ "$FILES" -gt "$FILEBACK" ] ; then
		FILEBACK=$((FILEBACK+NUM))
		cd $BACKUPDIR || exit
		ls -tp | grep -v '/$' | tail -n +$FILEBACK | xargs -I {} rm -- {}
		cd $LOGS || exit
		ls -tp | grep -v '/$' | tail -n +$FILEBACK | xargs -I {} rm -- {}
		echo "$(date +%Y-%m-%d_%H-%M-%S)" "Очистка старых файлов и логов" >> "$LOGS"/"$DATA".log
		return 0
	else
		echo "$(date +%Y-%m-%d_%H-%M-%S)" "Ошибка очистки старых файлов и логов" >> "$LOGS"/"$DATA".log
		return 1
	fi
}


Maintance()
{
	if [[ $(date "+%u") == 6 ]]; then
		echo "$(date +%Y-%m-%d_%H-%M-%S)" "Старт vacuumdb FULL" "$1" >> "$LOGS"/"$DATA".log
		if sudo -Hiu postgres /usr/bin/vacuumdb --full --analyze --username postgres --dbname "$1" > /dev/null 2>&1 ; then
			echo "$(date +%Y-%m-%d_%H-%M-%S)" "Конец vacuumdb FULL" "$1" >> "$LOGS"/"$DATA".log
		else
			echo "$(date +%Y-%m-%d_%H-%M-%S)" "Ошибка vacuumdb FULL" "$1" >> "$LOGS"/"$DATA".log
			exit
		fi
		echo "$(date +%Y-%m-%d_%H-%M-%S)" "Старт переиндексации" "$1" >> "$LOGS"/"$DATA".log
		if sudo -Hiu postgres /usr/bin/reindexdb --username postgres --dbname "$1" > /dev/null 2>&1 ; then
			echo "$(date +%Y-%m-%d_%H-%M-%S)" "Конец переиндексации" "$1" >> "$LOGS"/"$DATA".log
		else
			exit
		fi
		return 0
	else
		echo "$(date +%Y-%m-%d_%H-%M-%S)" "Старт vacuumdb" "$1" >> "$LOGS"/"$DATA".log
		if sudo -Hiu postgres /usr/bin/vacuumdb --analyze --username postgres --dbname "$1" > /dev/null 2>&1 ; then
			echo "$(date +%Y-%m-%d_%H-%M-%S)" "Конец vacuumdb" "$1" >> "$LOGS"/"$DATA".log
		else
			echo "$(date +%Y-%m-%d_%H-%M-%S)" "Ошибка vacuumdb" "$1" >> "$LOGS"/"$DATA".log
			exit
		fi
		return 0
	fi
}


for i in $(cat $BASES);
	do
		if Backup $i ; then
			Maintance $i
			ClearOldFiles $i
		else
			exit
		fi
	done

(date +%Y-%m-%d_%H-%M) > /var/log/timestamp
echo "$(date +%Y-%m-%d_%H-%M-%S)" "Создание файла для мониторинга" >> "$LOGS"/"$DATA".log