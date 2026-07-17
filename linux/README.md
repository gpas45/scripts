# linux/

Linux: тесты железа, конфиги окружения, 1С, motd.

| Файл | Назначение |
|---|---|
| `nvme_test.sh` | Тест NVMe-диска через fio по профилю CrystalDiskMark (SEQ1M Q8T1, SEQ128K Q32T1, RND4K Q32T8, RND4K Q1T1). Зависимости: `fio`, `jq`. |
| `setup-unattended-upgrades.sh` | Настройка автоматических обновлений безопасности (unattended-upgrades) на Debian/Ubuntu. |
| `1c/1c-server-manager.sh` | Менеджер сервера 1С:Предприятие 8.3 для Linux (Debian/Ubuntu/Astra/Mint), whiptail/dialog TUI: установка/обновление/удаление платформы (8.3.21+), управление несколькими экземплярами (рабочими серверами) через systemd-шаблон, включение/отключение отладки, установка веб-модуля ws + Apache и публикация баз. Дистрибутивы кладутся рядом со скриптом. Запуск от root. |
| `motd/` | Баннеры motd для серверов (1С, PostgreSQL, Proxmox) + генератор `99-mymotd-generator`. |
| `configs/.bashrc`, `configs/.bash_aliases` | Окружение bash для серверов. |
| `configs/commands.list` | Шпаргалка команд Linux по разделам (процессы, мониторинг, сеть и т.д.). |
