# routeros/

Скрипты и конфиги для MikroTik RouterOS.

| Файл | Назначение |
|---|---|
| `autorun.rsc` | Шаблон первичной настройки роутера: адресация, отключение небезопасных сервисов (telnet, ftp, api и т.д.), NTP, часовой пояс. Замените `CHANGE_ME` на свои значения. |
| `initial-setup.rsc` | Расширенный шаблон настройки: bridge, interface-lists (WAN/LAN/StS/VPN), полный firewall (port knocking, anti-bruteforce, ICMP), NAT, DNS, харднинг сервисов, OSPF-фильтры, автообновление прошивки. |
| `check-isp.rsc` | Проверка доступности двух провайдеров пингом и сброс соединений упавшего канала (для dual-WAN). |
| `rdp-bruteforce.rsc` | Защита от перебора RDP (TCP/3389): ступенчатое (`rdp_stage1`…`rdp_stage5`) добавление источников в `black-list attackers` с баном на 4w2d и правилом `drop` в filter. Списки `RDP` (доверенные клиенты) и `management` заполняются вручную; `192.168.0.0/16` не банится. |
| `cloudflare-ip-updater.rsc` | Обновление address-list `CF` актуальными IPv4-подсетями Cloudflare (по расписанию). |
| `telegram-ip-updater.rsc` | Обновление address-list `TG` актуальными IPv4-подсетями Telegram (по расписанию). |
| `google-ip-updater.rsc` | Обновление address-list `VPN_ytb` актуальными IPv4-диапазонами Google (goog.json) — для policy-routing на Google/YouTube (по расписанию). |
| `ospf_filter_rules` | Фильтры OSPF: принимать только частные подсети (RFC 1918). |
| `routerboard_fwupgrade` | Задание планировщика: автообновление прошивки RouterBOARD с перезагрузкой. |
| `routerboard_starwars` | Имперский марш на системном динамике после загрузки. |
| `BackupAndUpdate.rsc` | Автоматический бэкап MikroTik (система + конфиг) с отправкой на e-mail, уведомления о новых версиях RouterOS и автообновление прошивки RouterOS/RouterBOARD. Версия 26.02.22. |
| `docs/` | Obsidian-документация по установке каждого скрипта (`*-obsidian.md`), скриншоты-инструкции (`howto/`), чек-лист настройки роутера, продуктовая матрица MikroTik. |
