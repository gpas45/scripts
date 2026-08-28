# Скрипт первичной настройки RouterOS 7
# На основе routeros/autorun.scr, расширен списками интерфейсов и правилами firewall.
# Для RouterOS 6 используйте initial-setup-ros6.rsc (отличается синтаксис NTP /
# IPv6 / фильтров маршрутов / топиков логирования).
#
# Использование:
#   1. Просмотрите и поправьте плейсхолдеры CHANGE_ME / <...> ниже.
#   2. Назначьте реальные интерфейсы спискам LAN / WAN1 / StS / VPN в
#      секции "/interface list member" (WAN1 входит в WAN через include).
#   3. Загрузите на роутер и выполните:  /import file-name=initial-setup-ros7.rsc
#   4. Правила firewall "drop all other" намеренно используют action=passthrough:
#      на этапе первичной настройки трафик НЕ отбрасывается, а только логируется,
#      чтобы не потерять доступ к роутеру. После проверки логов и уверенности,
#      что вы себя не заблокируете, смените эти правила (в цепочках input и
#      forward) на action=drop.
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
add name=bridge comment="Local bridge"
# Порты намеренно не привязаны здесь — добавляйте их под каждое развёртывание, напр.:
# /interface bridge port
# add bridge=bridge interface=ether2

# ---------------------------------------------------------------------------
# Списки интерфейсов
# ---------------------------------------------------------------------------
/interface list
add name=WAN comment="Uplinks / Internet-facing interfaces"
add name=WAN1 comment="Uplink 1 (primary ISP)"
add name=LAN comment="Local trusted networks"
add name=StS comment="Site-to-Site tunnels"
add name=VPN comment="Remote-access VPN clients"
# WAN1 включён в состав WAN: интерфейс, добавленный в WAN1, автоматически
# считается членом WAN, поэтому правила по WAN (firewall, NAT, discovery)
# работают без повторного перечисления. Для второго аплинка заведите
# аналогично WAN2 и добавьте его в include: set [find name=WAN] include=WAN1,WAN2
set [find name=WAN] include=WAN1

/interface list member
# Назначьте здесь свои реальные интерфейсы, примеры ниже:
# Аплинк добавляйте в WAN1 (а не напрямую в WAN) — в WAN он попадёт через include:
# add list=WAN1 interface=ether1
add list=LAN interface=bridge
# add list=StS interface=<gre-tunnel1>
# add list=VPN interface=<wireguard1>

# ---------------------------------------------------------------------------
# Firewall filter
# ---------------------------------------------------------------------------
/ip firewall filter
# GRE должен стоять ПЕРЕД правилом drop invalid: у GRE нет отслеживания
# соединений, его пакеты помечаются как invalid и иначе будут отброшены.
# Правило выключено (disabled=yes) — включите (disabled=no) при использовании GRE.
add action=accept chain=input comment="accept GRE" disabled=yes in-interface-list=WAN protocol=gre
add action=accept chain=input comment="accept established, related connections" connection-state=established,related
add action=drop chain=input comment="drop invalid connections" connection-state=invalid log-prefix="DROP INPUT INVALID:"
add action=jump chain=input comment="jump for icmp input flow" jump-target=icmp protocol=icmp
add action=jump chain=input comment="detect intrusion" connection-state=new jump-target=detect-intrusion src-address-list=!management
add action=jump chain=input comment="port knocking" connection-state=new dst-port=1234,2345,3456 in-interface-list=WAN jump-target=pk log=yes protocol=tcp
add action=drop chain=input dst-port=12345 in-interface-list=WAN protocol=tcp src-address-list=!pk-1
add action=drop chain=input dst-port=12345 in-interface-list=WAN protocol=tcp src-address-list=!pk-2
add action=add-src-to-address-list address-list=management address-list-timeout=1d chain=input connection-state=new dst-port=12345 in-interface-list=WAN log=yes log-prefix=ACCESS! protocol=tcp src-address-list=pk-3
add action=accept chain=input comment="accept management" connection-state=new dst-port=22,8291,8729 log=yes log-prefix=ACCESS! protocol=tcp src-address-list=management
add action=accept chain=input comment="accept LAN" in-interface-list=LAN
add action=accept chain=input comment="accept StS" in-interface-list=StS
add action=accept chain=input comment="accept VPN" in-interface-list=VPN
# VPN / туннельные протоколы (L2TP / IPsec): правила выключены (disabled=yes),
# включите нужные (disabled=no) при терминировании туннелей на роутере.
# (GRE вынесен в начало цепочки — см. выше, до правила drop invalid.)
add action=accept chain=input comment="accept IPsec IKE (500,4500)" disabled=yes dst-port=500,4500 in-interface-list=WAN protocol=udp
add action=accept chain=input comment="accept IPsec ESP" disabled=yes in-interface-list=WAN protocol=ipsec-esp
add action=accept chain=input comment="accept IPsec AH" disabled=yes in-interface-list=WAN protocol=ipsec-ah
add action=accept chain=input comment="accept L2TP (1701)" disabled=yes dst-port=1701 in-interface-list=WAN protocol=udp
add action=passthrough chain=input comment="drop all other (see usage note 4: passthrough)" log-prefix="IN DROP"
add action=accept chain=forward comment="accept established, related connections" connection-state=established,related
add action=drop chain=forward comment="drop invalid connections" connection-state=invalid log-prefix="INV FWD"
add action=accept chain=forward comment="accept DST-NAT" connection-nat-state=dstnat
add action=drop chain=forward comment="WAN -X" in-interface-list=WAN log-prefix=FWD
add action=jump chain=forward comment=ICMP jump-target=icmp protocol=icmp
add action=accept chain=forward comment="LAN -> WAN" in-interface-list=LAN out-interface-list=WAN
add action=accept chain=forward comment="LAN -> StS" in-interface-list=LAN out-interface-list=StS
add action=accept chain=forward comment="LAN -> VPN" in-interface-list=LAN out-interface-list=VPN
add action=accept chain=forward comment="StS -> LAN" in-interface-list=StS out-interface-list=LAN
add action=accept chain=forward comment="VPN -> LAN" in-interface-list=VPN out-interface-list=LAN
add action=passthrough chain=forward comment="drop all other (see usage note 4: passthrough)" log-prefix=FWD
add action=accept chain=icmp comment="echo request" icmp-options=8:0 protocol=icmp
add action=accept chain=icmp comment="echo reply" icmp-options=0:0 protocol=icmp
add action=accept chain=icmp comment="net unreachable" icmp-options=3:3 protocol=icmp
add action=accept chain=icmp comment="host unreachable fragmentation required" icmp-options=3:4 protocol=icmp
add action=accept chain=icmp comment="time exceed" icmp-options=11:0 protocol=icmp
add action=drop chain=icmp comment="drop all other types"
add action=add-src-to-address-list address-list=pk-1 address-list-timeout=1m chain=pk comment=port-knocking dst-port=1234 protocol=tcp
add action=add-src-to-address-list address-list=pk-2 address-list-timeout=1m chain=pk connection-state="" dst-port=2345 protocol=tcp
add action=add-src-to-address-list address-list=pk-3 address-list-timeout=1m chain=pk connection-state="" dst-port=3456 protocol=tcp
add action=return chain=detect-intrusion comment="detect intrusion" dst-limit=30,256,src-and-dst-addresses/1s
add action=add-src-to-address-list address-list="black-list attackers" address-list-timeout=1d chain=detect-intrusion
add action=drop chain=detect-intrusion src-address-list="black-list attackers"

# ---------------------------------------------------------------------------
# Firewall NAT
# ---------------------------------------------------------------------------
/ip firewall nat
# Правило для WAN1 стоит первым: трафик, уходящий через аплинк WAN1,
# маскарадится этим правилом (удобно для отдельных счётчиков и для
# независимой настройки каждого аплинка). Общее правило по WAN ниже
# остаётся запасным — оно отработает для аплинков вне WAN1.
add action=masquerade chain=srcnat comment="LAN -> Internet (WAN1)" out-interface-list=WAN1
add action=masquerade chain=srcnat comment="LAN -> Internet" out-interface-list=WAN
# Если внешний адрес статический, предпочтительнее src-nat вместо masquerade:
# он не пересчитывает адрес на каждый пакет и не сбрасывает соединения при
# смене состояния интерфейса. Отключите правило masquerade выше и включите это,
# подставив свой публичный адрес:
# add action=src-nat chain=srcnat comment="LAN -> Internet (static)" out-interface-list=WAN to-addresses=203.0.113.1

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
set api-ssl disabled=no
/ip neighbor discovery-settings
set discover-interface-list=LAN
# MAC-сервер ограничен списком LAN: MAC-telnet / MAC-winbox доступны только
# из локальной сети и недоступны со стороны WAN.
/tool mac-server
set allowed-interface-list=LAN
/tool mac-server mac-winbox
set allowed-interface-list=LAN
/tool mac-server ping
set enabled=no
# Отключаем сервер bandwidth-test (по умолчанию открыт, частый вектор атаки).
/tool bandwidth-server
set enabled=no
# Полностью отключаем IPv6 (в RouterOS 7 IPv6 входит в монолитный пакет,
# поэтому выключается настройкой, а не удалением пакета).
/ipv6 settings
set disable-ipv6=yes

# ---------------------------------------------------------------------------
# Время / NTP
# ---------------------------------------------------------------------------
/system clock
set time-zone-name=Asia/Yekaterinburg
# RouterOS 7: серверы NTP задаются свойством клиента (подменю "servers" нет).
/system ntp client
set enabled=yes servers=pool.ntp.org

# Работать как NTP-сервер для нижестоящих клиентов.
/system ntp server
set enabled=yes

# ---------------------------------------------------------------------------
# Логирование — подавить info-сообщения для DHCP и беспроводной сети
# ---------------------------------------------------------------------------
# Подавляем info-сообщения DHCP.
/system logging
set [find where topics="info"] topics=info,!dhcp
# Пример: чтобы дополнительно подавить и беспроводные сообщения, добавьте
# соответствующий топик. В RouterOS 7 с драйвером wifi (wifiwave2) он называется
# "wifi", при legacy-пакете wireless — "wireless". Раскомментируйте нужное:
# set [find where topics="info"] topics=info,!dhcp,!wifi
# set [find where topics="info"] topics=info,!dhcp,!wireless

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
# Синтаксис фильтров маршрутов RouterOS 7 (rule="if (...) {accept;}").
# ---------------------------------------------------------------------------
/routing filter rule
add chain=ospf-in disabled=no rule="if (dst in 192.168.0.0/16 && dst-len in 16-32) {accept;}"
add chain=ospf-in disabled=no rule="if (dst in 10.0.0.0/8 && dst-len in 8-32) {accept;}"
add chain=ospf-in disabled=no rule="if (dst in 172.16.0.0/12 && dst-len in 12-32) {accept;}"
add chain=ospf-out disabled=no rule="if (dst in 192.168.0.0/16 && dst-len in 16-32) {accept;}"
add chain=ospf-out disabled=no rule="if (dst in 10.0.0.0/8 && dst-len in 8-32) {accept;}"
add chain=ospf-out disabled=no rule="if (dst in 172.16.0.0/12 && dst-len in 12-32) {accept;}"
