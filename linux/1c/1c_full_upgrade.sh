#!/bin/bash

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Этот скрипт должен запускаться с правами root${NC}"
    exit 1
fi

# Constants
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Functions
show_header() {
    echo -e "\n${GREEN}#################### МЕНЮ УПРАВЛЕНИЯ 1С #####################${NC}"
    echo -e "Доступные команды:"
    echo -e "  setup   - установка новой версии"
    echo -e "  update  - обновление существующей версии"
    echo -e "  remove  - удаление установленной версии"
    echo -e "  debug   - режим отладки"
    echo -e "  версия  - указание конкретной версии для операций"
    echo -e "Разместите дистрибутивы в той же директории, что и скрипт"
}

show_footer() {
    echo -e "\n${GREEN}############## ЗАВЕРШЕНИЕ РАБОТЫ ################${NC}\n"
}

check_version_format() {
    [[ $1 =~ ^8\.3\.[0-9]{2}\.[0-9]{4}$ ]]
}

compare_versions() {
    if [[ $1 == $2 ]]; then
        return 0
    fi
    local IFS=.
    local i ver1=($1) ver2=($2)
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do
        ver1[i]=0
    done
    for ((i=0; i<${#ver1[@]}; i++)); do
        if [[ -z ${ver2[i]} ]]; then
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]})); then
            return 1
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]})); then
            return 2
        fi
    done
    return 0
}

find_available_archives() {
    local available_versions=()
    
    # Поиск архивов (tar.gz/zip)
    for archive in server64_*.tar.gz server64_*.zip; do
        if [[ -f "$archive" ]]; then
            if [[ $archive =~ server64_(8_3_[0-9]{2}_[0-9]{4})\.(tar\.gz|zip) ]]; then
                version=$(echo "${BASH_REMATCH[1]}" | tr '_' '.')
                available_versions+=("$version")
            fi
        fi
    done
    
    # Удаляем дубликаты и сортируем версии (новые версии первыми)
    available_versions=($(echo "${available_versions[@]}" | tr ' ' '\n' | sort -ru | tr '\n' ' '))
    
    echo "${available_versions[@]}"
}

extract_distribution() {
    local version=$1
    local arcname=$(echo $version | sed 's/\./_/g')
    
    if [[ -f "setup-full-$version-x86_64.run" ]]; then
        echo -e "${GREEN}Найден дистрибутив платформы $version${NC}"
        return 0
    fi
    
    for ext in tar.gz zip; do
        if [[ -f "server64_$arcname.$ext" ]]; then
            echo -e "${YELLOW}Распаковываем дистрибутив, подождите...${NC}"
            if [[ $ext == "tar.gz" ]]; then
                tar -xzf "server64_$arcname.$ext"
            else
                unzip -u "server64_$arcname.$ext"
            fi
            return 0
        fi
    done
    
    echo -e "${RED}Не обнаружен дистрибутив платформы $version${NC}"
    return 1
}

install_dependencies() {
    echo -e "${YELLOW}Проверка и установка необходимых зависимостей...${NC}"
    
    # Обновляем список пакетов
    echo -e "${YELLOW}Обновляем информацию о пакетах...${NC}"
    apt-get update -y >/dev/null

    # Установка lsb-release если отсутствует
    if ! command -v lsb_release >/dev/null 2>&1; then
        echo -e "${YELLOW}Устанавливаем lsb-release...${NC}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y lsb-release >/dev/null || {
            echo -e "${RED}Ошибка установки lsb-release${NC}"
            return 1
        }
    else
        echo -e "${GREEN}lsb-release уже установлен${NC}"
    fi

    # Проверка libenchant1c2a (кроме AstraLinux)
    if [[ "$(lsb_release -si)" =~ ^AstraLinux ]]; then
        echo -e "${YELLOW}Astra Linux. Проверка libenchant1c2a пропущена${NC}"
    else
        if dpkg -s libenchant1c2a &>/dev/null; then
            echo -e "${GREEN}libenchant1c2a уже установлен${NC}"
        else
            codename=$(lsb_release -sc)
            case $codename in
                stretch|buster|bookworm|bionic|focal|tara|tessa|tina|tricia|ulyana|ulyssa|uma|una)
                    echo -e "${YELLOW}Устанавливаем libenchant1c2a...${NC}"
                    DEBIAN_FRONTEND=noninteractive apt-get install -y libenchant1c2a >/dev/null || \
                        echo -e "${YELLOW}Не удалось установить libenchant1c2a${NC}"
                    ;;
                *)
                    echo -e "${YELLOW}libenchant1c2a недоступен в стандартных репозиториях${NC}"
                    ;;
            esac
        fi
    fi

    # Список пакетов с точными именами как в репозиториях
    local packages=(
        ttf-mscorefonts-installer
        libodbc1
        unixodbc
        libgsf-1-114
        fontconfig
        imagemagick
        unzip
    )

    # Установка отсутствующих пакетов
    for pkg in "${packages[@]}"; do
        if dpkg -s "$pkg" &>/dev/null; then
            echo -e "${GREEN}${pkg} уже установлен${NC}"
        else
            echo -e "${YELLOW}Устанавливаем ${pkg}...${NC}"
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null || {
                echo -e "${RED}Ошибка установки ${pkg}${NC}"
                continue
            }
            
            # Дополнительные действия для шрифтов
            if [[ "$pkg" == "ttf-mscorefonts-installer" ]]; then
                echo -e "${YELLOW}Обновляем кэш шрифтов...${NC}"
                fc-cache -fv >/dev/null
            fi
        fi
    done

    echo -e "${GREEN}Все зависимости успешно проверены${NC}"
    return 0
}

# Секция RAS
install_ras() {
    local version=$1
    local arch="x86_64"
    
    echo -e "${YELLOW}Устанавливаем сервер RAS...${NC}"
    
    # Проверяем наличие файла службы RAS
    if [[ -f "/opt/1cv8/$arch/$version/ras-$version.service" ]]; then
        # Устанавливаем службу RAS
        systemctl link "/opt/1cv8/$arch/$version/ras-$version.service"
        systemctl enable "ras-$version"
        systemctl start "ras-$version"
        
        echo -e "${GREEN}Сервер RAS успешно установлен и запущен${NC}"
    else
        echo -e "${RED}Файлы RAS не найдены в /opt/1cv8/$arch/$version/${NC}"
        return 1
    fi
}

remove_ras() {
    local version=$1
    local service_name="ras-$version"
    
    if systemctl list-unit-files | grep -q "$service_name.service"; then
        echo -e "${YELLOW}Обнаружен установленный сервер RAS для версии $version${NC}"
        echo -e "${YELLOW}Останавливаем и удаляем сервер RAS...${NC}"
        
        systemctl stop "$service_name" 2>/dev/null
        systemctl disable "$service_name" 2>/dev/null
        rm -f "/etc/systemd/system/$service_name.service"
        systemctl daemon-reload
        
        echo -e "${GREEN}Сервер RAS для версии $version успешно удалён${NC}"
        return 0
    else
        echo -e "${YELLOW}Сервер RAS для версии $version не найден${NC}"
        return 1
    fi
}

# Секция платформы
install_platform() {
    local version=$1
    local web=${2:-"no"}  # По умолчанию "no"
    local components="--mode unattended --enable-components server"
    local install_success=true

    # Проверка минимальной версии
    if [ "$(printf "%s\n" "8.3.21" "$version" | sort -V | head -n1)" != "8.3.21" ]; then
        echo -e "${RED}Ошибка: Поддерживаются только версии 8.3.21 и выше${NC}"
        return 1
    fi
    
    # Проверка наличия дистрибутива
    if [[ ! -f "./setup-full-$version-x86_64.run" ]]; then
        echo -e "${RED}Ошибка: Дистрибутив setup-full-$version-x86_64.run не найден${NC}"
        return 1
    fi

    # Добавляем компонент веб-сервера при необходимости
    [[ $web == "yes" ]] && components+=",ws"

    echo -e "${YELLOW}Устанавливаем платформу $version...${NC}"
    
    # Установка основного пакета
    if ! ./setup-full-$version-x86_64.run $components; then
        echo -e "${RED}Ошибка установки платформы $version${NC}"
        return 1
    fi

    # Настройка systemd службы
    echo -e "${YELLOW}Настраиваем systemd службу...${NC}"
    
    local service_file="/opt/1cv8/x86_64/$version/srv1cv8-$version@.service"
    if [[ -f "$service_file" ]]; then
        if ! systemctl link "$service_file"; then
            echo -e "${RED}Ошибка создания символьной ссылки службы${NC}"
            install_success=false
        fi

        if ! systemctl enable "srv1cv8-$version@default"; then
            echo -e "${RED}Ошибка включения службы${NC}"
            install_success=false
        fi

        if ! systemctl start "srv1cv8-$version@default"; then
            echo -e "${RED}Ошибка запуска службы${NC}"
            install_success=false
        fi
    else
        echo -e "${RED}Файл службы $service_file не найден${NC}"
        install_success=false
    fi

    # Проверка успешности установки
    if ! $install_success; then
        echo -e "${YELLOW}Установка завершена с ошибками${NC}"
        return 1
    fi

    echo -e "${GREEN}Платформа $version успешно установлена${NC}"

    # Проверка работы службы
    if ! systemctl is-active --quiet "srv1cv8-$version@default"; then
        echo -e "${YELLOW}Предупреждение: Служба не запущена${NC}"
    else
        echo -e "${GREEN}Служба успешно запущена${NC}"
    fi

    return 0
}

find_installed_versions() {
    local installed_versions=()
    local version
    
    # 1. Поиск старых версий (до 8.3.20) через dpkg
    if dpkg -l | grep -q 1c-enterprise; then
        while read -r version; do
            # Проверяем, что версия действительно старая (<8.3.20)
            if [[ $version < '8.3.20' ]]; then
                installed_versions+=("$version")
            fi
        done < <(dpkg -l | grep 1c-enterprise | awk '{print $3}' | cut -d'-' -f1 | sort -u)
    fi

    # 2. Поиск новых версий (8.3.20 и выше) через каталоги
    if [[ -d "/opt/1cv8/x86_64" ]]; then
        while read -r version; do
            # Проверяем, что каталог не пустой и есть uninstaller-full
            if [[ -f "/opt/1cv8/x86_64/$version/uninstaller-full" ]]; then
                installed_versions+=("$version")
            fi
        done < <(ls /opt/1cv8/x86_64/ 2>/dev/null | grep -E '^8\.3\.[0-9]{2}\.[0-9]{4}$' | sort -ru)
    fi

    # 3. Удаляем возможные дубликаты (хотя маловероятно)
    installed_versions=($(printf "%s\n" "${installed_versions[@]}" | sort -u))

    # 4. Проверяем, что массив не пустой
    if [[ ${#installed_versions[@]} -eq 0 ]]; then
        echo -e "${YELLOW}Не найдено установленных версий 1С${NC}" >&2
        return 1
    fi

    echo "${installed_versions[@]}"
    return 0
}

remove_platform() {
    local version=$1
    echo -e "${YELLOW}Начинаем удаление платформы $version...${NC}"

    # Удаляем RAS для этой версии
    remove_ras "$version"

    # Сначала останавливаем службы независимо от версии
    if [[ $version < '8.3.21' ]]; then
        echo -e "${YELLOW}Останавливаем службу srv1cv83...${NC}"
        systemctl stop srv1cv83 2>/dev/null
    else
        echo -e "${YELLOW}Останавливаем службу srv1cv8-$version@default...${NC}"
        systemctl stop "srv1cv8-$version@default" 2>/dev/null
    fi
    
    if [[ $version < '8.3.20' ]]; then
        # Удаление старых версий (до 8.3.20)
        if dpkg -l | grep -q "1c-enterprise$version"; then
            echo -e "${YELLOW}Удаляем пакеты старого формата...${NC}"
            apt remove -y $(dpkg -l | grep "1c-enterprise" | awk '{print $2}')
            
            echo -e "${YELLOW}Удаляем конфигурационные файлы...${NC}"
            rm -f /etc/init.d/srv1cv83 /etc/default/srv1cv83
            
            # Отключаем автозагрузку для старых версий
            update-rc.d -f srv1cv83 remove 2>/dev/null
        else
            echo -e "${RED}Версия $version не найдена в системе${NC}"
            return 1
        fi
    else
        # Удаление новых версий (8.3.20 и выше)
        if [[ -f "/opt/1cv8/x86_64/$version/uninstaller-full" ]]; then
            echo -e "${YELLOW}Запускаем деинсталлятор...${NC}"
            /opt/1cv8/x86_64/$version/uninstaller-full --mode unattended
            
            # Отключаем службы для новых версий
            if [[ $version < '8.3.21' ]]; then
                echo -e "${YELLOW}Отключаем службу srv1cv83...${NC}"
                systemctl disable srv1cv83 2>/dev/null
                rm -f /etc/init.d/srv1cv83 /etc/default/srv1cv83
            else
                echo -e "${YELLOW}Отключаем службу srv1cv8-$version@default...${NC}"
                systemctl disable "srv1cv8-$version@default" 2>/dev/null
            fi
          
        else
            echo -e "${RED}Файлы версии $version не найдены${NC}"
            return 1
        fi
    fi
    
    echo -e "${GREEN}Платформа $version успешно удалена${NC}"
    return 0
}

show_installed_versions() {
    echo -e "\n${YELLOW}Список установленных версий:${NC}"
    versions=($(find_installed_versions))
    if [ ${#versions[@]} -eq 0 ]; then
        echo -e "${RED}Не найдено установленных версий 1С${NC}"
        return 1
    fi
    
    for i in "${!versions[@]}"; do
        echo "$((i+1)). ${versions[$i]}"
    done
    return 0
}

process_installation() {
    local action=$1
    local newver=$2
    local oldver=$3
    
    if ! check_version_format "$newver"; then
        echo -e "${RED}Неверный формат версии${NC}"
        return 1
    fi
    
    if [[ $newver < '8.3.20' ]]; then
        echo -e "${RED}Версии ниже 8.3.20 не поддерживаются${NC}"
        return 1
    fi
    
    # Добавляем проверку на попытку отката версии
    if [[ $action == "update" ]]; then
        compare_versions "$newver" "$oldver"
        case $? in
            1)  # Новая версия действительно новее
                echo -e "${GREEN}Обновление с $oldver на более новую версию $newver${NC}"
                ;;
            2)  # Новая версия старше существующей
                echo -e "${RED}ВНИМАНИЕ! Вы пытаетесь установить более старую версию ($newver) вместо текущей ($oldver)!${NC}"
                echo -e "${YELLOW}Это может привести к проблемам с совместимостью баз данных!${NC}"
                read -p "Вы действительно хотите продолжить? (y/N): " confirm
                if [[ ! $confirm =~ ^[Yy] ]]; then
                    echo -e "${YELLOW}Отменено пользователем${NC}"
                    return 1
                fi
                echo -e "${YELLOW}Продолжаем установку более старой версии по требованию пользователя${NC}"
                ;;
            0)  # Версии одинаковые
                echo -e "${YELLOW}Версии идентичны ($oldver -> $newver), нет необходимости в обновлении${NC}"
                return 1
                ;;
        esac
    fi
    
    if ! extract_distribution "$newver"; then
        return 1
    fi
    
    echo -e "\n${YELLOW}Будет выполнено:${NC}"
    if [[ $action == "setup" ]]; then
        echo "- Установка новой версии $newver"
    else
        echo "- Обновление с $oldver на $newver"
        
        # Удаление RAS старой версии
        remove_ras "$oldver"
        
        # Удаление старой версии платформы
        echo -e "${YELLOW}Удаляем старую версию $oldver...${NC}"
        if ! remove_platform "$oldver"; then
            echo -e "${RED}Ошибка при удалении старой версии $oldver${NC}"
            return 1
        fi
    fi
    
    read -p "Подтвердите (y/N): " confirm
    if [[ ! $confirm =~ ^[Yy] ]]; then
        echo -e "${YELLOW}Отменено пользователем${NC}"
        return
    fi
    
    read -p "Установить модуль веб-сервера? (y/N): " web_choice
    web="no"
    [[ $web_choice =~ ^[Yy] ]] && web="yes"
    
    install_dependencies
    install_platform "$newver" "$web"
    
    # Предложение установить RAS после успешной установки платформы
    if [[ $? -eq 0 ]]; then
        read -p "Установить сервер RAS для версии $newver? [y/N]: " install_ras_choice
        if [[ $install_ras_choice =~ ^[Yy] ]]; then
            if ! install_ras "$newver"; then
                echo -e "${YELLOW}Не удалось установить сервер RAS${NC}"
            else
                echo -e "${GREEN}Сервер RAS успешно установлен${NC}"
            fi
        fi
    fi
    
    read -p "Нажмите Enter для продолжения..."
}

# Экземпляры
create_instance() {
    local version=$1
    local instance_name=$2
    local port=$3
    local regport=$4
    local range=$5

    # Проверяем, что версия установлена
    if [[ ! -f "/opt/1cv8/x86_64/$version/srv1cv8-$version@.service" ]]; then
        echo -e "${RED}Шаблон службы для версии $version не найден${NC}"
        return 1
    fi

    if [[ -z "$instance_name" ]]; then
        read -p "Введите имя нового экземпляра (например: 2x): " instance_name
        if [[ -z "$instance_name" ]]; then
            echo -e "${RED}Имя экземпляра не может быть пустым${NC}"
            return 1
        fi
    fi

    # Проверяем существование конфигурации после получения имени экземпляра
    local dropin_dir="/etc/systemd/system/srv1cv8-$version@$instance_name.service.d"
    local override_file="$dropin_dir/override.conf"
    
    if [[ -f "$override_file" ]]; then
        echo -e "${YELLOW}Внимание: файл конфигурации $override_file уже существует!${NC}"
        echo -e "${YELLOW}Это может означать, что экземпляр с таким именем уже создан.${NC}"
        read -p "Вы действительно хотите продолжить? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy] ]]; then
            echo -e "${YELLOW}Создание экземпляра отменено пользователем${NC}"
            return 1
        fi
    fi

    # Устанавливаем порты по умолчанию
    port=${port:-2540}
    regport=${regport:-2541}
    range=${range:-2560:2591}

    # Проверяем доступность портов
    if ss -tulpn | grep -qE ":${port}\b"; then
        echo -e "${RED}Ошибка: Порт ${port} уже занят${NC}"
        return 1
    fi

    if ss -tulpn | grep -qE ":${regport}\b"; then
        echo -e "${RED}Ошибка: Регистрационный порт ${regport} уже занят${NC}"
        return 1
    fi

    # Создаем каталог для данных экземпляра
    local data_dir="/home/usr1cv8/.1cv8/1C/1cv8_${instance_name}"
    echo -e "${YELLOW}Создаем каталог данных: ${data_dir}${NC}"
    mkdir -p "$data_dir" || {
        echo -e "${RED}Ошибка создания каталога данных${NC}"
        return 1
    }
    chown -R usr1cv8:grp1cv8 "$data_dir" || {
        echo -e "${RED}Ошибка изменения прав на каталог данных${NC}"
        return 1
    }

    # Создаем drop-in конфигурацию
    echo -e "${YELLOW}Создаем конфигурацию в ${dropin_dir}/override.conf${NC}"
    mkdir -p "$dropin_dir" || {
        echo -e "${RED}Ошибка создания директории для конфигурации${NC}"
        return 1
    }

    # Проверяем версию для возможности отладки (строго выше 8.3.21)
    local can_debug=false
    if [[ "$(printf "%s\n" "8.3.21" "$version" | sort -V | tail -n1)" == "$version" ]]; then
        can_debug=true
    fi

    # Предлагаем включить отладку только для поддерживаемых версий
    local debug_choice="n"
    if $can_debug; then
        read -p "Включить отладку для этого экземпляра? (y/N): " debug_choice
    fi

    # Создаем файл override.conf
    cat > "$override_file" <<EOF
[Service]
Environment=SRV1CV8_DATA=${data_dir}
Environment=SRV1CV8_PORT=${port}
Environment=SRV1CV8_REGPORT=${regport}
Environment=SRV1CV8_RANGE=${range}
EOF

    if [[ "$debug_choice" =~ ^[Yy] && $can_debug ]]; then
        read -p "Выберите тип отладки (1 - TCP, 2 - HTTP): " debug_type
        
        if [[ "$debug_type" == "1" ]]; then
            debug_protocol="tcp"
            echo "Environment=SRV1CV8_DEBUG=\"-debug -tcp\"" >> "$override_file"
            echo -e "${GREEN}Отладка TCP включена${NC}"
        else
            debug_protocol="http"
            echo "Environment=SRV1CV8_DEBUG=\"-debug -http\"" >> "$override_file"
            echo -e "${GREEN}Отладка HTTP включена${NC}"
        fi

        # Создаем конфигурацию для внешних соединений
        local conf_dir="/opt/1cv8/conf"
        mkdir -p "$conf_dir"
        cat > "$conf_dir/comcntrcfg.xml" <<EOF
<config xmlns="http://v8.1c.ru/v8/comcntrcfg">
   <debugconfig debug="true" protocol="${debug_protocol}" debuggerURL="${debug_protocol}://localhost:${port}"/>
</config>
EOF
        echo -e "${GREEN}Создан файл конфигурации внешней отладки: ${conf_dir}/comcntrcfg.xml${NC}"
    fi

    # Применяем изменения
    echo -e "${YELLOW}Применяем изменения systemd...${NC}"
    systemctl daemon-reload || {
        echo -e "${RED}Ошибка перезагрузки демона systemd${NC}"
        return 1
    }

    # Включаем и запускаем службу
    echo -e "${YELLOW}Активируем службу srv1cv8-$version@$instance_name${NC}"
    systemctl enable "srv1cv8-$version@$instance_name" || {
        echo -e "${RED}Ошибка включения службы${NC}"
        return 1
    }

    echo -e "${YELLOW}Запускаем службу...${NC}"
    systemctl start "srv1cv8-$version@$instance_name" || {
        echo -e "${RED}Ошибка запуска службы${NC}"
        return 1
    }

    # Проверяем статус
    local status=$(systemctl is-active "srv1cv8-$version@$instance_name")
    echo -e "${GREEN}Экземпляр успешно создан:${NC}"
    echo -e "• Имя экземпляра: ${instance_name}"
    echo -e "• Версия платформы: ${version}"
    echo -e "• Основной порт: ${port}"
    echo -e "• Регистрационный порт: ${regport}"
    echo -e "• Диапазон портов: ${range}"
    echo -e "• Каталог данных: ${data_dir}"
    echo -e "• Статус службы: ${status}"
    
    # Показываем статус отладки
    if grep -q "SRV1CV8_DEBUG" "$override_file" 2>/dev/null; then
        echo -e "• Отладка: ${GREEN}включена${NC}"
        if grep -q "http" "$override_file"; then
            echo -e "  • Тип отладки: HTTP"
        else
            echo -e "  • Тип отладки: TCP"
        fi
    else
        echo -e "• Отладка: ${YELLOW}выключена${NC}"
    fi
    
    echo -e "• Путь к конфигурации: ${override_file}"
    echo -e "• Команда управления: systemctl [start|stop|restart] srv1cv8-$version@$instance_name"

    return 0
}

list_instances() {
    echo -e "\n${GREEN}Список рабочих серверов 1С:${NC}"
    
    local services=($(systemctl list-units --all --no-legend --no-pager --plain 'srv1cv8*@*' | awk '{print $1}'))
    
    if [ ${#services[@]} -eq 0 ]; then
        echo -e "${YELLOW}Нет зарегистрированных рабочих серверов${NC}"
        return 1
    fi

    for service in "${services[@]}"; do
        local instance=$(echo "$service" | cut -d'@' -f2 | cut -d'.' -f1)
        local version=$(echo "$service" | grep -oP 'srv1cv8-\K[\d.]+(?=@)')
        local status=$(systemctl is-active "$service" 2>/dev/null || echo "unknown")
        local port=$(systemctl show "$service" --property=Environment --no-pager | grep -oP 'SRV1CV8_PORT=\K\d+')
        
        # Получаем статус отладки
        local debug_status=""
        local debug_file="/etc/systemd/system/${service}.d/override.conf"
        if [[ -f "$debug_file" ]]; then
            if grep -q "http" "$debug_file"; then
                debug_status=" (${RED}Отладка HTTP${NC})"
            elif grep -q "debug" "$debug_file"; then
                debug_status=" (${YELLOW}Отладка TCP${NC})"
            fi
        fi
        
        echo -e "• ${GREEN}${instance}${NC}${debug_status} (Версия: ${version:-N/A}, Порт: ${port:-N/A}, Статус: ${status})"
    done
}

remove_instance() {
    local version=$1
    local instance_name=$2

    if [[ -z "$instance_name" ]]; then
        list_instances
        read -p "Введите имя рабочего сервера для удаления: " instance_name
        if [[ -z "$instance_name" ]]; then
            echo -e "${RED}Имя рабочего сервера не может быть пустым${NC}"
            return 1
        fi
    fi

    # Останавливаем и отключаем сервис
    systemctl stop "srv1cv8-${version}@${instance_name}"
    systemctl disable "srv1cv8-${version}@${instance_name}"

    # Удаляем drop-in конфигурацию
    local dropin_file="/etc/systemd/system/srv1cv8-${version}@${instance_name}.service.d/override.conf"
    if [[ -f "$dropin_file" ]]; then
        rm -f "$dropin_file"
    fi

    # Удаляем каталог данных (по подтверждению)
    local data_dir="/home/usr1cv8/.1cv8/1C/1cv8_${instance_name}"
    if [[ -d "$data_dir" ]]; then
        read -p "Удалить каталог данных (${data_dir})? [y/N]: " confirm
        if [[ $confirm =~ ^[Yy] ]]; then
            rm -rf "$data_dir"
            echo -e "${YELLOW}Каталог данных удален${NC}"
        fi
    fi

    systemctl daemon-reload
    echo -e "${GREEN}Рабочий сервер '${instance_name}' успешно удален${NC}"
}


#Меню
show_action_menu() {
    echo -e "\n${GREEN}Главное меню управления сервером 1С:${NC}"
    echo "1. Установка/обновление/удаление платформы 1С"
    echo "2. Управление экземплярами 1С"
    echo "3. Список версий"
    echo "4. Выход"
}


# Модифицированное меню управления экземплярами
show_instance_menu() {
    echo -e "\n${GREEN}Меню управления экземплярами:${NC}"
    echo "1. Список экземпляров"
    echo "2. Создать экземпляр"
    echo "3. Удалить экземпляр"
    echo "4. Вернуться в главное меню"
}

main() {
    show_header
    
    while true; do
        show_action_menu
        read -p "Введите номер действия (1-4): " choice

        case $choice in
            1)  # Установка/обновление/удаление платформы 1С
                echo -e "\n${GREEN}Меню управления платформой:${NC}"
                echo "1. Установить новую версию"
                echo "2. Обновить существующую версию"
                echo "3. Удалить версию"
                echo "4. Вернуться в главное меню"
                read -p "Выберите действие (1-4): " platform_choice

                case $platform_choice in
                    1)  # Установка новой версии
                        available_versions=($(find_available_archives))
                        if [ ${#available_versions[@]} -eq 0 ]; then
                            echo -e "${RED}Нет доступных дистрибутивов в текущей директории${NC}"
                            continue
                        fi
                        
                        echo -e "\n${GREEN}Доступные версии для установки:${NC}"
                        for i in "${!available_versions[@]}"; do
                            echo "$((i+1)). ${available_versions[$i]}"
                        done
                        
                        read -p "Выберите версию (1-${#available_versions[@]}): " ver_choice
                        if [[ $ver_choice =~ ^[0-9]+$ ]] && [ $ver_choice -ge 1 -a $ver_choice -le ${#available_versions[@]} ]; then
                            selected_version="${available_versions[$((ver_choice-1))]}"
                            process_installation "setup" "$selected_version"
                        else
                            echo -e "${RED}Некорректный выбор версии${NC}"
                        fi
                        ;;

                    2)  # Обновление существующей версии
                        if ! installed_versions=($(find_installed_versions)); then
                            echo -e "${RED}Не найдено установленных версий для обновления${NC}"
                            continue
                        fi

                        echo -e "\n${GREEN}Выберите версию для обновления:${NC}"
                        for i in "${!installed_versions[@]}"; do
                            echo "$((i+1)). ${installed_versions[$i]}"
                        done
                        
                        read -p "Введите номер (1-${#installed_versions[@]}): " old_ver_choice
                        if [[ $old_ver_choice =~ ^[0-9]+$ ]] && [ $old_ver_choice -ge 1 -a $old_ver_choice -le ${#installed_versions[@]} ]; then
                            old_version="${installed_versions[$((old_ver_choice-1))]}"
                            
                            available_versions=($(find_available_archives))
                            if [ ${#available_versions[@]} -eq 0 ]; then
                                echo -e "${RED}Нет доступных дистрибутивов в текущей директории${NC}"
                                continue
                            fi
                            
                            echo -e "\n${GREEN}Доступные версии для обновления:${NC}"
                            for i in "${!available_versions[@]}"; do
                                echo "$((i+1)). ${available_versions[$i]}"
                            done
                            
                            read -p "Выберите новую версию (1-${#available_versions[@]}): " new_ver_choice
                            if [[ $new_ver_choice =~ ^[0-9]+$ ]] && [ $new_ver_choice -ge 1 -a $new_ver_choice -le ${#available_versions[@]} ]; then
                                new_version="${available_versions[$((new_ver_choice-1))]}"
                                process_installation "update" "$new_version" "$old_version"
                            else
                                echo -e "${RED}Некорректный выбор версии${NC}"
                            fi
                        else
                            echo -e "${RED}Некорректный выбор версии${NC}"
                        fi
                        ;;

                    3)  # Удаление версии
                        if ! versions=($(find_installed_versions)); then
                            echo -e "${RED}Не найдено установленных версий для удаления${NC}"
                            continue
                        fi

                        echo -e "\n${GREEN}Выберите версию для удаления:${NC}"
                        for i in "${!versions[@]}"; do
                            echo "$((i+1)). ${versions[$i]}"
                        done
                        
                        read -p "Введите номер (1-${#versions[@]}): " ver_choice
                        if [[ $ver_choice =~ ^[0-9]+$ ]] && [ $ver_choice -ge 1 -a $ver_choice -le ${#versions[@]} ]; then
                            ver_to_remove="${versions[$((ver_choice-1))]}"
                            echo -e "\n${YELLOW}Будет удалена версия: $ver_to_remove${NC}"
                            read -p "Подтвердите удаление (y/N): " confirm
                            if [[ $confirm =~ ^[Yy] ]]; then
                                remove_platform "$ver_to_remove"
                                read -p "Нажмите Enter для продолжения..."
                            fi
                        else
                            echo -e "${RED}Некорректный выбор${NC}"
                        fi
                        ;;

                    4)  # Выход
                        continue
                        ;;

                    *)
                        echo -e "${RED}Некорректный выбор${NC}"
                        ;;
                esac
                ;;

            2)  # Управление экземплярами
                if ! versions=($(find_installed_versions)); then
                    echo -e "${RED}Для управления рабочими серверами необходимо установить платформу 1С${NC}"
                    continue
                fi
                
                echo -e "\n${GREEN}Доступные версии:${NC}"
                for i in "${!versions[@]}"; do
                    echo "$((i+1)). ${versions[$i]}"
                done
                
                read -p "Выберите версию (1-${#versions[@]}): " ver_choice
                if [[ $ver_choice =~ ^[0-9]+$ ]] && [ $ver_choice -ge 1 -a $ver_choice -le ${#versions[@]} ]; then
                    version="${versions[$((ver_choice-1))]}"
                    
                    while true; do
                        show_instance_menu
                        read -p "Введите номер действия (1-4): " instance_choice
                        
                        case $instance_choice in
                            1)  # Список экземпляров
                                list_instances
                                ;;
                                
                            2)  # Создать экземпляр
                                read -p "Введите имя экземпляра (например 2x): " instance_name
                                read -p "Введите порт (по умолчанию 2540): " port
                                read -p "Введите регистрационный порт (по умолчанию 2541): " regport
                                read -p "Введите диапазон портов (по умолчанию 2560:2591): " range
                                
                                create_instance "$version" "$instance_name" "${port:-2540}" "${regport:-2541}" "${range:-2560:2591}"
                                ;;
                                
                            3)  # Удалить экземпляр
                                list_instances
                                read -p "Введите имя экземпляра для удаления: " instance_name
                                if [[ -n "$instance_name" ]]; then
                                    remove_instance "$version" "$instance_name"
                                else
                                    echo -e "${RED}Имя экземпляра не может быть пустым${NC}"
                                fi
                                ;;
                                
                            4)  # Выход
                                break
                                ;;
                                
                            *)
                                echo -e "${RED}Некорректный выбор${NC}"
                                ;;
                        esac
                    done
                else
                    echo -e "${RED}Некорректный выбор${NC}"
                fi
                ;;
            
            3)  # Список версий
                show_installed_versions
                read -p "Нажмите Enter для продолжения..."
                ;;
            
            4)  # Выход
                echo -e "${YELLOW}Выход из программы${NC}"
                show_footer
                exit 0
                ;;
            
            *)
                echo -e "${RED}Некорректный выбор. Введите число от 1 до 4${NC}"
                ;;
        esac
    done
}

# Установка рабочей директории
cd "$(dirname "$0")"

# Запуск главной функции
main
