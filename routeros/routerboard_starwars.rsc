# RouterBOARD Star Wars — имперский марш на старте (RouterOS 6.x / 7.x)
# Создаёт scheduler, который через 15 секунд после загрузки проигрывает на
# встроенном динамике (beeper) тему имперского марша.
#
# Нужно устройство со встроенным динамиком — без него :beep ничего не делает.
#
# Установка:
#   /import file-name=routerboard_starwars.rsc
#
# Удаление:
#   /system scheduler remove [find name=starwars]

/system scheduler
add name=starwars on-event=":delay 15;\r\
    \n \r\
    \n:beep frequency=500 length=500ms;:delay 500ms;\r\
    \n:beep frequency=500 length=500ms;:delay 500ms;\r\
    \n:beep frequency=500 length=500ms;:delay 500ms;\r\
    \n:beep frequency=400 length=500ms;:delay 400ms;\r\
    \n:beep frequency=600 length=200ms;:delay 100ms;\r\
    \n:beep frequency=500 length=500ms;:delay 500ms;\r\
    \n:beep frequency=400 length=500ms;:delay 400ms;\r\
    \n:beep frequency=600 length=200ms;:delay 100ms;\r\
    \n:beep frequency=500 length=500ms;:delay 1000ms;\r\
    \n \r\
    \n:beep frequency=750 length=500ms;:delay 500ms;\r\
    \n:beep frequency=750 length=500ms;:delay 500ms;\r\
    \n:beep frequency=750 length=500ms;:delay 500ms;\r\
    \n:beep frequency=810 length=500ms;:delay 400ms;\r\
    \n:beep frequency=600 length=200ms;:delay 100ms;\r\
    \n:beep frequency=470 length=500ms;:delay 500ms;\r\
    \n:beep frequency=400 length=500ms;:delay 400ms;\r\
    \n:beep frequency=600 length=200ms;:delay 100ms;\r\
    \n:beep frequency=500 length=500ms;:delay 1000ms;" policy=reboot,read,write \
    start-time=startup
