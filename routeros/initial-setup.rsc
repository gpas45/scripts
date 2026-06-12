# RouterOS initial setup script
# Based on routeros/autorun.scr, extended with interface lists and firewall rules.
#
# Usage:
#   1. Review and adjust the placeholders marked CHANGE_ME / <...> below.
#   2. Assign real interfaces to the LAN / WAN / StS / VPN lists in the
#      "/interface list member" section.
#   3. Upload to the router and run:  /import file-name=initial-setup.rsc
#
# Notes:
#   StS = Site-to-Site tunnels, VPN = remote-access VPN clients.
#   Port knocking sequence: 1234 -> 2345 -> 3456, then connect to 12345.

# Per-provider settings (addresses, routes, dhcp-client, user passwords)
# are intentionally NOT included here — configure them separately for each
# uplink / deployment.

# ---------------------------------------------------------------------------
# Bridge
# ---------------------------------------------------------------------------
/interface bridge
add name=bridge comment="Local bridge"
# Ports are intentionally not bound here — add them per deployment, e.g.:
# /interface bridge port
# add bridge=bridge interface=ether2

# ---------------------------------------------------------------------------
# Interface lists
# ---------------------------------------------------------------------------
/interface list
add name=WAN comment="Uplinks / Internet-facing interfaces"
add name=LAN comment="Local trusted networks"
add name=StS comment="Site-to-Site tunnels"
add name=VPN comment="Remote-access VPN clients"

/interface list member
# Assign your real interfaces here, examples below:
add list=WAN interface=ether1
add list=LAN interface=bridge
# add list=StS interface=<gre-tunnel1>
# add list=VPN interface=<wireguard1>

# ---------------------------------------------------------------------------
# Firewall filter
# ---------------------------------------------------------------------------
/ip firewall filter
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
add action=passthrough chain=input comment="drop all other" log-prefix="IN DROP"
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
add action=passthrough chain=forward comment="drop all other" log-prefix=FWD
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
# DNS — resolver for LAN / VPN / StS clients
# ---------------------------------------------------------------------------
/ip dns
set allow-remote-requests=yes servers=1.1.1.1,8.8.8.8
# DNS queries are accepted from LAN / VPN / StS by the input chain rules above
# and dropped from WAN by default.

# ---------------------------------------------------------------------------
# Service / management hardening
# ---------------------------------------------------------------------------
/ip service
set telnet disabled=yes
set ftp disabled=yes
set www disabled=yes
set api disabled=yes
set api-ssl disabled=yes
/ip neighbor discovery-settings
set discover-interface-list=none
# MAC-server is left enabled on all interfaces so the router stays reachable
# via MAC-telnet / MAC-winbox during initial setup from any port, before it has
# an IP address. NOTE: this also exposes MAC access on WAN — restrict to a
# management interface list once setup is complete.
/tool mac-server
set allowed-interface-list=all
/tool mac-server mac-winbox
set allowed-interface-list=all
/tool mac-server ping
set enabled=yes
/ipv6 settings
set disable-ipv6=yes

# ---------------------------------------------------------------------------
# Time / NTP
# ---------------------------------------------------------------------------
/system clock
set time-zone-name=Asia/Yekaterinburg
/system ntp client
set enabled=yes
/system ntp client servers
add address=pool.ntp.org

# Act as an NTP server for downstream clients.
/system ntp server
set enabled=yes

# ---------------------------------------------------------------------------
# Logging — suppress info-level messages for DHCP and Wireless
# ---------------------------------------------------------------------------
/system logging
set [find where topics="info"] topics=info,!dhcp,!wireless

# ---------------------------------------------------------------------------
# RouterBOARD firmware auto-upgrade
# Upgrades the RouterBOARD firmware on startup when a newer one is available,
# then reboots to apply it.
# ---------------------------------------------------------------------------
/system scheduler
add name=routerboard_fwupgrade policy=reboot,read,write,sensitive start-time=startup \
    on-event="if ([/system routerboard get current-firmware] != [/system routerboard get upgrade-firmware]) do={\r\
    \n/system routerboard upgrade\r\
    \n:delay 15s\r\
    \n/system reboot\r\
    \n}"

# ---------------------------------------------------------------------------
# OSPF routing filters — accept only local (RFC1918) prefixes in/out
# ---------------------------------------------------------------------------
/routing filter rule
add chain=ospf-in disabled=no rule="if (dst in 192.168.0.0/16 && dst-len in 16-32) {accept;}"
add chain=ospf-in disabled=no rule="if (dst in 10.0.0.0/8 && dst-len in 8-32) {accept;}"
add chain=ospf-in disabled=no rule="if (dst in 172.16.0.0/12 && dst-len in 12-32) {accept;}"
add chain=ospf-out disabled=no rule="if (dst in 192.168.0.0/16 && dst-len in 16-32) {accept;}"
add chain=ospf-out disabled=no rule="if (dst in 10.0.0.0/8 && dst-len in 8-32) {accept;}"
add chain=ospf-out disabled=no rule="if (dst in 172.16.0.0/12 && dst-len in 12-32) {accept;}"
