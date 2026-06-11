#!/bin/bash

# Constants
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Functions
show_header() {
    echo -e "\n${GREEN}#################### НАЧАЛО РАБОТЫ #####################${NC}"
    echo -e "Этот скрипт установит/обновит компоненту веб-сервера (ws) 1С"
    echo -e "и настроит публикацию базы в Apache"
    echo -e "(c) Уваров А.С. 2023-2024 interface31.ru\n"
}

show_footer() {
    echo -e "\n${GREEN}############## ЗАВЕРШЕНИЕ РАБОТЫ ################${NC}\n"
}

check_version_format() {
    [[ $1 =~ ^8\.3\.[0-9]{2}\.[0-9]{4}$ ]]
}

is_installed() {
    [[ -f "/opt/1cv8/x86_64/$1/ws/apache2.4/mod_1c.so" ]]
}

remove_old_platform() {
    local version=$1
    echo -e "${YELLOW}Удаляем старую платформу $version...${NC}"
    
    /opt/1cv8/x86_64/$version/uninstaller-full --mode unattended
    echo -e "${GREEN}Платформа $version удалена${NC}"
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
    echo -e "${YELLOW}Проверяем и устанавливаем зависимости...${NC}"
    apt update -y > /dev/null
    apt install -y lsb-release apache2 libapache2-mod-wsgi
}

configure_mpm_worker() {
    echo -e "${YELLOW}Проверяем и настраиваем MPM Worker...${NC}"
    
    # Отключаем все MPM модули
    for mpm in $(apache2ctl -M | grep mpm_ | awk '{print $1}'); do
        a2dismod -q $mpm
    done
    
    # Включаем mpm_worker
    a2enmod mpm_worker
    
    # Перезапускаем Apache
    systemctl restart apache2
    
    echo -e "${GREEN}MPM Worker успешно настроен${NC}"
}

install_ws_component() {
    local version=$1
    
    echo -e "${YELLOW}Устанавливаем компоненту ws (веб-сервер 1С)...${NC}"
    ./setup-full-$version-x86_64.run --mode unattended --enable-components ws
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}Компонента ws успешно установлена${NC}"
    else
        echo -e "${RED}Ошибка установки компоненты ws${NC}"
        exit 1
    fi
}

publish_infobase() {
    local version=$1
    
    read -p "Введите название информационной базы: " ib_name
    read -p "Введите адрес сервера 1С (например, SRV-1C): " srv_address
    
    # Создаем каталог для публикации
    local publish_dir="/var/www/$ib_name"
    mkdir -p "$publish_dir"
    chown -R www-data:www-data "$publish_dir"
    
    # Публикуем базу
    echo -e "${YELLOW}Публикуем информационную базу $ib_name...${NC}"
    
    /opt/1cv8/x86_64/$version/webinst \
        -publish \
        -apache24 \
        -wsdir "$ib_name" \
        -dir "$publish_dir" \
        -connstr "Srvr=$srv_address;Ref=$ib_name;" \
        -confpath /etc/apache2/apache2.conf
    
    # Проверяем результат публикации
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}Информационная база успешно опубликована${NC}"
        systemctl restart apache2
    else
        echo -e "${RED}Ошибка публикации информационной базы${NC}"
        exit 1
    fi
}

# Main script
show_header

# Установка рабочей директории
cd "$(dirname "$0")"

read -p "Введите версию платформы 1С для установки (например, 8.3.23.1752): " version

if ! check_version_format "$version"; then
    echo -e "${RED}Неверный формат версии платформы${NC}"
    show_footer
    exit 1
fi

if [[ $version < '8.3.20' ]]; then
    echo -e "${RED}Платформа версии ниже 8.3.20 не поддерживается${NC}"
    show_footer
    exit 1
fi

# Проверяем установлена ли старая версия
if is_installed "$version"; then
    read -p "Версия $version уже установлена. Обновить? (yes/no): " update
    if [[ $update == "yes" ]]; then
        remove_old_platform "$version"
    else
        echo -e "${YELLOW}Отменено пользователем${NC}"
        show_footer
        exit 0
    fi
fi

if ! extract_distribution "$version"; then
    show_footer
    exit 1
fi

install_dependencies
configure_mpm_worker
install_ws_component "$version"
publish_infobase "$version"

show_footer