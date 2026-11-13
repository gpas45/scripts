# Wake-on-LAN по обращению на порт (RouterOS 6.x / 7.x)
#
# Будит выключенный компьютер, когда кто-то постучался на заданный TCP-порт:
# правило firewall кладёт источник в address-list "wol-trigger", а этот скрипт,
# запускаемый планировщиком раз в несколько секунд, видит непустой список и
# отправляет магический пакет через /tool wol.
#
# Прямого «хука на срабатывание правила» в RouterOS нет, поэтому опрос
# address-list — штатный способ связать событие в firewall со скриптом.
#
# Защита от повторов:
#   - список "wol-trigger" очищается при каждом срабатывании;
#   - если компьютер уже отвечает на ping, пакет не отправляется;
#   - после отправки на $cooldown ставится блокировка через address-list
#     "wol-cooldown", чтобы не слать WoL каждые 5 секунд, пока машина грузится.
#
# --- Установка -------------------------------------------------------------
#
# 1. Загрузить файл на роутер и поправить секцию НАСТРОЙКИ ниже
#    (Winbox/WebFig -> Files -> Edit):
#    /tool fetch url="https://raw.githubusercontent.com/gpas45/scripts/main/routeros/wol-on-port.rsc"
#
# 2. Создать именованный скрипт и задачу планировщика:
#    /system script
#    add name=wol-on-port policy=read,write,test source=[/file get wol-on-port.rsc contents]
#    /system scheduler
#    add name=wol-on-port interval=5s policy=read,write,test on-event="/system script run wol-on-port"
#
# 3. Добавить правило-триггер в firewall (выбрать один вариант):
#
#    А. Порт проброшен на сам компьютер (стучимся из интернета на RDP):
#    /ip firewall filter
#    add chain=forward protocol=tcp dst-port=3389 dst-address=192.168.88.10 \
#        action=add-src-to-address-list address-list=wol-trigger \
#        address-list-timeout=30s comment="wol-on-port trigger" place-before=0
#
#    Б. «Секретный» порт самого роутера (port knocking, слушать ничего не надо):
#    /ip firewall filter
#    add chain=input protocol=tcp dst-port=9999 \
#        action=add-src-to-address-list address-list=wol-trigger \
#        address-list-timeout=30s comment="wol-on-port trigger" place-before=0
#
#    add-src-to-address-list — нетерминирующее действие, пакет идёт дальше по
#    цепочке, существующие правила не ломаются. place-before=0 обязателен:
#    правило должно стоять выше любых drop.
#
# Ручная проверка: /tool wol mac=AA:BB:CC:DD:EE:FF interface=vlan3
# Логи:            /log print where message~"wol-on-port"

# --- НАСТРОЙКИ --------------------------------------------------------------

# MAC компьютера, который надо разбудить.
:local mac "CHANGE_ME_MAC"

# Интерфейс, в котором физически живёт компьютер. ВАЖНО: при vlan-filtering=yes
# указывать не бридж, а конкретный VLAN-интерфейс (vlan3, vlan5, ...), иначе
# магический пакет уйдёт нетегированным в PVID бриджа и до машины не доедет.
# Как узнать: /ip dhcp-server lease print where mac-address="AA:BB:CC:DD:EE:FF"
:local iface "CHANGE_ME_IFACE"

# IP компьютера: используется для проверки «уже включён» и как ключ cooldown.
:local pcip "CHANGE_ME_IP"

# Проверять пингом, не включён ли компьютер уже. Поставить false, если у
# роутера нет IP-адреса в той же подсети или ICMP на машине закрыт.
:local checkPing true

# Сколько не повторять отправку после успешного WoL (время загрузки машины).
:local cooldown 2m

# --- ЛОГИКА -----------------------------------------------------------------

:local trig "wol-trigger"
:local cool "wol-cooldown"

:if ([:len [/ip firewall address-list find list=$trig]] > 0) do={

    # Сбрасываем триггер сразу: повторный стук создаст его заново.
    /ip firewall address-list remove [find list=$trig]

    :if ([:len [/ip firewall address-list find list=$cool]] > 0) do={
        :log debug "wol-on-port: cooldown is active, skipping"
    } else={

        :local alive false
        :if ($checkPing) do={
            :if ([/ping $pcip count=2] > 0) do={ :set alive true }
        }

        :if ($alive) do={
            :log info ("wol-on-port: " . $pcip . " is already up, nothing to do")
        } else={
            :do {
                /tool wol mac=$mac interface=$iface
                /ip firewall address-list add list=$cool address=$pcip \
                    timeout=$cooldown comment="wol-on-port cooldown"
                :log info ("wol-on-port: magic packet sent to " . $mac . " via " . $iface)
            } on-error={
                :log error ("wol-on-port: failed to send WoL to " . $mac . " via " . $iface)
            }
        }
    }
}
