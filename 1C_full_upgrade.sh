#!/bin/bash

# Constants
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Functions
show_header() {
    echo -e "\n${GREEN}#################### НАЧАЛО РАБОТЫ #####################${NC}"
    echo -e "Этот скрипт поможет обновить или установить сервер 1С"
    echo -e "Разместите дистрибутив в той же директории, что и скрипт"
    echo -e "(c) Уваров А.С. 2023-2024 interface31.ru\n"
}

show_footer() {
    echo -e "\n${GREEN}############## ЗАВЕРШЕНИЕ РАБОТЫ ################${NC}\n"
}

check_version_format() {
    [[ $1 =~ ^8\.3\.[0-9]{2}\.[0-9]{4}$ ]]
}

is_installed() {
    if [[ $1 < '8.3.20' ]]; then
        dpkg -l | grep -q "$1"
    else
        [[ -f "/opt/1cv8/x86_64/$1/uninstaller-full" ]]
    fi
}

remove_old_platform() {
    local version=$1
    echo -e "${YELLOW}Удаляем старую платформу $version...${NC}"
    
    if [[ $version < '8.3.20' ]]; then
        systemctl stop srv1cv83
        update-rc.d -f srv1cv83 remove
        apt remove $(dpkg -l | grep 1c-enterprise | grep ^ii | awk '{print $2}') -y
        rm -f /etc/init.d/srv1cv83 /etc/default/srv1cv83
    elif [[ $version < '8.3.21' ]]; then
        systemctl stop srv1cv83
        update-rc.d -f srv1cv83 remove
        /opt/1cv8/x86_64/$version/uninstaller-full --mode unattended
        rm -f /etc/init.d/srv1cv83 /etc/default/srv1cv83
    else
        systemctl stop "srv1cv8-$version@default"
        systemctl disable "srv1cv8-$version@"
        /opt/1cv8/x86_64/$version/uninstaller-full --mode unattended
    fi
    
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
    if ! dpkg -l | grep -q lsb-release; then
        echo -e "${YELLOW}Устанавливаем необходимые зависимости...${NC}"
        apt update -y > /dev/null
        apt install -y lsb-release
    fi
    
    if [[ ! "$(lsb_release -si)" =~ ^AstraLinux ]] && ! dpkg -l | grep -q libenchant1c2a; then
        local codename=$(lsb_release -sc)
        case $codename in
            stretch|buster|bionic|focal|tara|tessa|tina|tricia|ulyana|ulyssa|uma|una)
                echo -e "${GREEN}Проверка зависимостей выполнена${NC}"
                ;;
            *)
                echo -e "${RED}Пакет libenchant1c2a недоступен в репозиториях!${NC}"
                read -p "Добавить репозиторий Debian 10? (yes/no): " libenchant
                if [[ $libenchant == "yes" ]]; then
                    if ! dpkg -l | grep -qw gnupg2; then
                        apt update -y > /dev/null
                        apt install -y gnupg2
                    fi
                    gpg --no-default-keyring --keyring /usr/share/keyrings/debian-archive-keyring.gpg \
                        --keyserver keyserver.ubuntu.com --recv "648ACFD622F3D138"
                    echo "deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://ftp.ru.debian.org/debian buster main" \
                        > /etc/apt/sources.list.d/buster.list
                    apt update -y > /dev/null
                fi
                ;;
        esac
    fi
}

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

install_platform() {
    local version=$1
    local components="--mode unattended --enable-components server"
    
    if [[ $2 == "yes" ]]; then
        components+=",ws"
    fi
    
    echo -e "${YELLOW}Устанавливаем новую платформу $version...${NC}"
    ./setup-full-$version-x86_64.run $components
    
    if [[ $version < '8.3.21' ]]; then
        ln -fs "/opt/1cv8/x86_64/$version/srv1cv83" /etc/init.d/srv1cv83
        ln -fs "/opt/1cv8/x86_64/$version/srv1cv83.conf" /etc/default/srv1cv83
        update-rc.d srv1cv83 defaults
        systemctl start srv1cv83
        
        read -p "Удалить минимальную конфигурацию Gnome (рекомендуется)? (yes/no): " nognome
        if [[ $nognome == "yes" ]]; then
            apt purge -y gnome-shell gnome-control-center gnome-keyring
            apt autoremove -y
        fi
    else
        systemctl link "/opt/1cv8/x86_64/$version/srv1cv8-$version@.service"
        systemctl enable "srv1cv8-$version@"
        systemctl start "srv1cv8-$version@default"
    fi
    
    echo -e "${GREEN}Платформа $version успешно установлена${NC}"
    
    # Предлагаем установить RAS после установки платформы
    read -p "Установить сервер RAS? (yes/no): " install_ras
    if [[ $install_ras == "yes" ]]; then
        install_ras "$version"
    fi
}

# Main script
show_header

# Установка рабочей директории
cd "$(dirname "$0")"

read -p "Введите 'setup' для установки, 'debug' для отладки или версию для обновления: " oldver

case $oldver in
    debug)
        # Код для отладки (оставлен без изменений)
        ;;
    setup)
        ;;
    *)
        if ! check_version_format "$oldver"; then
            echo -e "${RED}Неверный формат версии платформы${NC}"
            show_footer
            exit 1
        fi
        
        if ! is_installed "$oldver"; then
            echo -e "${RED}Не обнаружена установленная версия платформы $oldver${NC}"
            show_footer
            exit 1
        fi
        
        echo -e "\nПлатформа $oldver будет удалена"
        read -p "Для продолжения введите yes: " confirm
        if [[ $confirm != "yes" ]]; then
            echo -e "${YELLOW}Отменено пользователем${NC}"
            show_footer
            exit 0
        fi
        
        remove_old_platform "$oldver"
        ;;
esac

read -p "Введите номер новой платформы: " newver

if ! check_version_format "$newver"; then
    echo -e "${RED}Неверный формат версии платформы${NC}"
    show_footer
    exit 1
fi

if [[ $newver < '8.3.20' ]]; then
    echo -e "${RED}Платформа версии ниже 8.3.20 не поддерживается${NC}"
    show_footer
    exit 1
fi

if ! extract_distribution "$newver"; then
    show_footer
    exit 1
fi

echo -e "\nПлатформа $newver будет установлена"
read -p "Для продолжения введите yes: " confirm
if [[ $confirm != "yes" ]]; then
    echo -e "${YELLOW}Отменено пользователем${NC}"
    show_footer
    exit 0
fi

read -p "Требуется установка модуля расширения веб-сервера? (yes/no): " web
install_dependencies
install_platform "$newver" "$web"

show_footershow_footer