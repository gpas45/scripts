# RouterOS minimal autorun / bootstrap script
# Basic connectivity + service hardening + time sync.
# Adjust the CHANGE_ME placeholders before importing:
#   /import file-name=autorun.rsc

# ---------------------------------------------------------------------------
# Basic connectivity (per-deployment — adjust address / gateway)
# ---------------------------------------------------------------------------
/ip address
add address=10.0.0.2/24 interface=ether1 comment="CHANGE_ME: address issued by ISP"
/ip route
add dst-address=0.0.0.0/0 gateway=10.0.0.1 comment="CHANGE_ME: default gateway"
/ip dhcp-client
add interface=ether1 disabled=yes

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
# add list=LAN interface=bridge
# add list=StS interface=<gre-tunnel1>
# add list=VPN interface=<wireguard1>

# ---------------------------------------------------------------------------
# Firewall NAT
# ---------------------------------------------------------------------------
/ip firewall nat
add action=masquerade chain=srcnat comment="LAN -> Internet" out-interface-list=WAN

# ---------------------------------------------------------------------------
# Admin user
# ---------------------------------------------------------------------------
/user
set 0 password="CHANGE_ME"

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
/tool mac-server
set allowed-interface-list=none
/tool mac-server mac-winbox
set allowed-interface-list=none
/tool mac-server ping
set enabled=no
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
