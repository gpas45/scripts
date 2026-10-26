# RouterBOARD firmware auto-upgrade (RouterOS 6.x / 7.x)
# Создаёт scheduler, который при каждой загрузке сверяет текущую прошивку
# RouterBOARD с доступной (идёт в комплекте с установленным RouterOS) и,
# если появилась новее, обновляет её и перезагружает роутер.
#
# Прошивка RouterBOARD обновляется отдельно от пакетов RouterOS, поэтому
# проверка на старте — после планового апгрейда RouterOS — оптимальна:
# зацикливания нет, т.к. после применения current-firmware == upgrade-firmware.
#
# Установка:
#   /import file-name=routerboard_fwupgrade.rsc
#
# На новых устройствах (RouterOS 7.17+) заводской device-mode может запрещать
# scheduler. Проверка: /system device-mode print
# Разрешить:    /system device-mode update mode=advanced
# затем подтвердить физически — кнопка reset/mode или снятие питания.

/system scheduler
add name=routerboard_fwupgrade comment="Auto-upgrade RouterBOARD firmware at startup" \
    policy=reboot,read,write,sensitive start-time=startup \
    on-event="if ([/system routerboard get current-firmware] != [/system routerboard get upgrade-firmware]) do={\r\
    \n:log warning \"routerboard_fwupgrade: new firmware available, upgrading...\";\r\
    \n/system routerboard upgrade;\r\
    \n:delay 15s;\r\
    \n:log warning \"routerboard_fwupgrade: firmware applied, rebooting now\";\r\
    \n/system reboot;\r\
    \n} else={\r\
    \n:log info \"routerboard_fwupgrade: firmware is up to date\";\r\
    \n}"
