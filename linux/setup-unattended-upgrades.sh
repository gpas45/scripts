#!/bin/bash
set -euo pipefail

# Константы
CONFIG_50="/etc/apt/apt.conf.d/50unattended-upgrades"
CONFIG_20="/etc/apt/apt.conf.d/20auto-upgrades"
EMAIL="gpas@dioservice.ru"
SENDER="itsp72@gmail.com"

# Функция для создания бэкапа файла
backup_file() {
    local file=$1
    if [ -f "$file" ]; then
        cp -v "$file" "${file}.bak"
    fi
}

# Проверка прав root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Ошибка: скрипт должен быть запущен от имени root!" >&2
        exit 1
    fi
}

# Установка необходимых пакетов
install_packages() {
    if ! dpkg -l unattended-upgrades >/dev/null 2>&1; then
        apt-get update && apt-get install -y unattended-upgrades
    fi
}

# Определение типа системы
detect_system() {
    if grep -qs "Proxmox Backup Server" /etc/issue; then
        echo "pbs"
    elif grep -qs "Proxmox Virtual Environment" /etc/issue; then
        echo "pve"
    else
        echo "debian"
    fi
}

# Проверка наличия Docker
check_docker() {
    if dpkg -l docker-ce >/dev/null 2>&1 || \
       dpkg -l docker.io >/dev/null 2>&1 || \
       command -v docker >/dev/null 2>&1; then
        echo true
    else
        echo false
    fi
}

# Генерация конфигурации для 50unattended-upgrades
generate_config() {
    local system_type=$1
    local has_docker=$2

    # Базовые настройки
    cat > "$CONFIG_50" <<EOF
Unattended-Upgrade::Origins-Pattern {
EOF

    # Общие репозитории для всех систем
    cat >> "$CONFIG_50" <<EOF
    "origin=Debian,codename=\${distro_codename},label=Debian";
    "origin=Debian,codename=\${distro_codename}-security,label=Debian-Security";
    "origin=Debian,codename=\${distro_codename}-updates,label=Debian-Updates";
EOF

    # Специфичные репозитории
    case "$system_type" in
        "pve") echo '    "origin=Proxmox,codename=${distro_codename},label=pve-no-subscription";' >> "$CONFIG_50" ;;
        "pbs") echo '    "origin=Proxmox,codename=${distro_codename},label=pbs-no-subscription";' >> "$CONFIG_50" ;;
    esac

    # Репозиторий Docker при необходимости
    if "$has_docker"; then
        echo '    "origin=Docker,a=bookworm,l=Docker CE";' >> "$CONFIG_50"
    fi

    # Основные параметры
    cat >> "$CONFIG_50" <<EOF
};
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Mail "$EMAIL";
Unattended-Upgrade::Sender "$SENDER";
Unattended-Upgrade::MailReport "only-on-error";
Unattended-Upgrade::Remove-Unused-kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

    # Исключения для Docker
    if "$has_docker"; then
        cat >> "$CONFIG_50" <<EOF
Unattended-Upgrade::Package-Blacklist {
    "docker-ce";
    "docker-ce-cli";
    "containerd.io";
    "docker.io";
};
EOF
    fi
}

# Настройка автоматических обновлений
setup_auto_upgrades() {
    cat > "$CONFIG_20" <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF
}

# Запуск службы
enable_service() {
    systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
    systemctl restart unattended-upgrades >/dev/null 2>&1 || true
}

# Основной поток выполнения
main() {
    check_root
    install_packages
    
    # Создание бэкапов
    backup_file "$CONFIG_50"
    backup_file "$CONFIG_20"
    
    local system_type has_docker
    system_type=$(detect_system)
    has_docker=$(check_docker)
    
    generate_config "$system_type" "$has_docker"
    setup_auto_upgrades
    enable_service

    echo -e "\nНастройка завершена успешно!"
    echo "Тип системы: $system_type"
    echo "Docker: $([ "$has_docker" = "true" ] && echo "установлен" || echo "отсутствует")"
    echo "Логи: /var/log/unattended-upgrades/unattended-upgrades.log"
    echo "Бэкапы созданы:"
    ls -la ${CONFIG_50}* ${CONFIG_20}*
}

main
