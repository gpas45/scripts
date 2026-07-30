# Скрипт первичной настройки RouterOS
# На основе routeros/autorun.scr, расширен списками интерфейсов и правилами firewall.
#
# Использование:
#   1. Просмотрите и поправьте плейсхолдеры CHANGE_ME / <...> ниже.
#   2. Назначьте реальные интерфейсы спискам LAN / WAN / StS / VPN в
#      секции "/interface list member".
#   3. Загрузите на роутер и выполните:  /import file-name=initial-setup.rsc
#   4. Правила firewall "отбрасывать всё остальное" намеренно используют
#      action=passthrough: на этапе первичной настройки трафик НЕ отбрасывается,
#      а только логируется — чтобы не потерять доступ к роутеру. После проверки
#      логов и уверенности, что вы себя не заблокируете, смените эти правила
#      (в цепочках input и forward) на action=drop.
#
# Примечания:
#   StS = туннели site-to-site, VPN = удалённые VPN-клиенты.
#   Последовательность port knocking: 1234 -> 2345 -> 3456, затем подключение к 12345.

# Настройки, зависящие от провайдера (адреса, маршруты, dhcp-клиент, пароли
# пользователей) намеренно НЕ включены — настраивайте их отдельно для каждого
# аплинка / развёртывания.

# ---------------------------------------------------------------------------
# Мост (bridge)
# ---------------------------------------------------------------------------
/interface bridge
add name=bridge comment="Локальный мост"
# Порты намеренно не привязаны здесь — добавляйте их под каждое развёртывание, напр.:
# /interface bridge port
# add bridge=bridge interface=ether2

# ---------------------------------------------------------------------------
# Списки интерфейсов
# ---------------------------------------------------------------------------
/interface list
add name=WAN comment="Аплинки / интерфейсы, смотрящие в интернет"
add name=LAN comment="Локальные доверенные сети"
add name=StS comment="Туннели site-to-site"
add name=VPN comment="Удалённые VPN-клиенты"

/interface list member
# Назначьте здесь свои реальные интерфейсы, примеры ниже:
add list=WAN interface=ether1
add list=LAN interface=bridge
# add list=StS interface=<gre-tunnel1>
# add list=VPN interface=<wireguard1>

# ---------------------------------------------------------------------------
# Firewall filter
# ---------------------------------------------------------------------------
/ip firewall filter
add action=accept chain=input comment="принимать established/related соединения" connection-state=established,related
add action=drop chain=input comment="отбрасывать invalid соединения" connection-state=invalid log-prefix="DROP INPUT INVALID:"
add action=jump chain=input comment="переход в цепочку icmp для входящих" jump-target=icmp protocol=icmp
add action=jump chain=input comment="обнаружение вторжений" connection-state=new jump-target=detect-intrusion src-address-list=!management
add action=jump chain=input comment="port knocking" connection-state=new dst-port=1234,2345,3456 in-interface-list=WAN jump-target=pk log=yes protocol=tcp
add action=drop chain=input dst-port=12345 in-interface-list=WAN protocol=tcp src-address-list=!pk-1
add action=drop chain=input dst-port=12345 in-interface-list=WAN protocol=tcp src-address-list=!pk-2
add action=add-src-to-address-list address-list=management address-list-timeout=1d chain=input connection-state=new dst-port=12345 in-interface-list=WAN log=yes log-prefix=ACCESS! protocol=tcp src-address-list=pk-3
add action=accept chain=input comment="принимать управляющий доступ" connection-state=new dst-port=22,8291,8729 log=yes log-prefix=ACCESS! protocol=tcp src-address-list=management
add action=accept chain=input comment="принимать LAN" in-interface-list=LAN
add action=accept chain=input comment="принимать StS" in-interface-list=StS
add action=accept chain=input comment="принимать VPN" in-interface-list=VPN
add action=passthrough chain=input comment="отбрасывать всё остальное (см. п.4 шапки: passthrough)" log-prefix="IN DROP"
add action=accept chain=forward comment="принимать established/related соединения" connection-state=established,related
add action=drop chain=forward comment="отбрасывать invalid соединения" connection-state=invalid log-prefix="INV FWD"
add action=accept chain=forward comment="принимать DST-NAT" connection-nat-state=dstnat
add action=drop chain=forward comment="WAN -X" in-interface-list=WAN log-prefix=FWD
add action=jump chain=forward comment=ICMP jump-target=icmp protocol=icmp
add action=accept chain=forward comment="LAN -> WAN" in-interface-list=LAN out-interface-list=WAN
add action=accept chain=forward comment="LAN -> StS" in-interface-list=LAN out-interface-list=StS
add action=accept chain=forward comment="LAN -> VPN" in-interface-list=LAN out-interface-list=VPN
add action=accept chain=forward comment="StS -> LAN" in-interface-list=StS out-interface-list=LAN
add action=accept chain=forward comment="VPN -> LAN" in-interface-list=VPN out-interface-list=LAN
add action=passthrough chain=forward comment="отбрасывать всё остальное (см. п.4 шапки: passthrough)" log-prefix=FWD
add action=accept chain=icmp comment="эхо-запрос" icmp-options=8:0 protocol=icmp
add action=accept chain=icmp comment="эхо-ответ" icmp-options=0:0 protocol=icmp
add action=accept chain=icmp comment="сеть недоступна" icmp-options=3:3 protocol=icmp
add action=accept chain=icmp comment="хост недоступен / требуется фрагментация" icmp-options=3:4 protocol=icmp
add action=accept chain=icmp comment="превышение времени (time exceeded)" icmp-options=11:0 protocol=icmp
add action=drop chain=icmp comment="отбрасывать все прочие типы"
add action=add-src-to-address-list address-list=pk-1 address-list-timeout=1m chain=pk comment=port-knocking dst-port=1234 protocol=tcp
add action=add-src-to-address-list address-list=pk-2 address-list-timeout=1m chain=pk connection-state="" dst-port=2345 protocol=tcp
add action=add-src-to-address-list address-list=pk-3 address-list-timeout=1m chain=pk connection-state="" dst-port=3456 protocol=tcp
add action=return chain=detect-intrusion comment="обнаружение вторжений" dst-limit=30,256,src-and-dst-addresses/1s
add action=add-src-to-address-list address-list="black-list attackers" address-list-timeout=1d chain=detect-intrusion
add action=drop chain=detect-intrusion src-address-list="black-list attackers"

# ---------------------------------------------------------------------------
# Firewall NAT
# ---------------------------------------------------------------------------
/ip firewall nat
add action=masquerade chain=srcnat comment="LAN -> Internet" out-interface-list=WAN

# ---------------------------------------------------------------------------
# DNS — резолвер для клиентов LAN / VPN / StS
# ---------------------------------------------------------------------------
/ip dns
set allow-remote-requests=yes servers=1.1.1.1,8.8.8.8
# DNS-запросы принимаются от LAN / VPN / StS правилами цепочки input выше
# и по умолчанию отбрасываются со стороны WAN.

# ---------------------------------------------------------------------------
# Сервисы / усиление безопасности управления
# ---------------------------------------------------------------------------
/ip service
set telnet disabled=yes
set ftp disabled=yes
set www disabled=yes
set api disabled=yes
set api-ssl disabled=yes
/ip neighbor discovery-settings
set discover-interface-list=LAN
# MAC-server оставлен включённым на всех интерфейсах, чтобы роутер оставался
# доступен по MAC-telnet / MAC-winbox во время первичной настройки с любого
# порта, пока у него ещё нет IP-адреса. ВНИМАНИЕ: это также открывает MAC-доступ
# на WAN — после завершения настройки ограничьте его управляющим списком интерфейсов.
/tool mac-server
set allowed-interface-list=all
/tool mac-server mac-winbox
set allowed-interface-list=all
/tool mac-server ping
set enabled=yes
# Отключаем сервер bandwidth-test (по умолчанию открыт, частый вектор атаки).
/tool bandwidth-server
set enabled=no

# ---------------------------------------------------------------------------
# Отключение неиспользуемых пакетов (только RouterOS 6)
# Отключает пакеты hotspot, ipv6 и mpls. Изменения применяются после
# перезагрузки роутера. Отключение пакета ipv6 — это способ полностью
# выключить IPv6 в RouterOS 6 (заменяет "/ipv6 settings set disable-ipv6=yes").
# ---------------------------------------------------------------------------
/system package disable hotspot,ipv6,mpls

# ---------------------------------------------------------------------------
# Время / NTP
# ---------------------------------------------------------------------------
/system clock
set time-zone-name=Asia/Yekaterinburg
/system ntp client
set enabled=yes
/system ntp client servers
add address=pool.ntp.org

# Работать как NTP-сервер для нижестоящих клиентов.
/system ntp server
set enabled=yes

# ---------------------------------------------------------------------------
# Логирование — подавить info-сообщения для DHCP и беспроводной сети
# ---------------------------------------------------------------------------
/system logging
set [find where topics="info"] topics=info,!dhcp,!wireless,!wifi

# ---------------------------------------------------------------------------
# Канал обновления пакетов RouterOS — использовать ветку long-term (стабильную)
# ---------------------------------------------------------------------------
/system package update
set channel=long-term

# ---------------------------------------------------------------------------
# Авто-обновление прошивки RouterBOARD
# Обновляет прошивку RouterBOARD при старте, если доступна более новая,
# затем перезагружается для её применения.
# ---------------------------------------------------------------------------
/system scheduler
add name=routerboard_fwupgrade policy=reboot,read,write,sensitive start-time=startup \
    on-event="if ([/system routerboard get current-firmware] != [/system routerboard get upgrade-firmware]) do={\r\
    \n/system routerboard upgrade\r\
    \n:delay 15s\r\
    \n/system reboot\r\
    \n}"

# ---------------------------------------------------------------------------
# Фильтры маршрутизации OSPF — принимать только локальные (RFC1918) префиксы вх/исх
# ---------------------------------------------------------------------------
/routing filter rule
add chain=ospf-in disabled=no rule="if (dst in 192.168.0.0/16 && dst-len in 16-32) {accept;}"
add chain=ospf-in disabled=no rule="if (dst in 10.0.0.0/8 && dst-len in 8-32) {accept;}"
add chain=ospf-in disabled=no rule="if (dst in 172.16.0.0/12 && dst-len in 12-32) {accept;}"
add chain=ospf-out disabled=no rule="if (dst in 192.168.0.0/16 && dst-len in 16-32) {accept;}"
add chain=ospf-out disabled=no rule="if (dst in 10.0.0.0/8 && dst-len in 8-32) {accept;}"
add chain=ospf-out disabled=no rule="if (dst in 172.16.0.0/12 && dst-len in 12-32) {accept;}"
