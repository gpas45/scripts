# RDP brute-force protection for MikroTik RouterOS.
#
# Detects repeated new RDP (TCP/3389) connection attempts aimed at hosts behind
# the router and escalates every offending source through five staged
# address-lists. A source that keeps hammering RDP eventually lands in
# "black-list attackers" and is banned for 4w2d.
#
# How the staging works (the rules are ordered high stage -> low stage on
# purpose, so a single new connection advances a source by only one stage per
# pass and never cascades through all lists at once):
#
#   unknown source        -> rdp_stage1           (3m)
#   already in rdp_stage1  -> rdp_stage2           (3m)
#   already in rdp_stage2  -> rdp_stage3           (3m)
#   already in rdp_stage3  -> rdp_stage4           (3m)
#   already in rdp_stage4  -> rdp_stage5           (5m)
#   already in rdp_stage5  -> black-list attackers (4w2d)   <-- banned & dropped
#
# Address-lists you maintain yourself:
#   RDP         - trusted RDP clients, always accepted (whitelist).
#   management  - management hosts that must never be staged or banned.
# Sources inside 192.168.0.0/16 are never banned.
#
# Import once:  /import file-name=rdp-bruteforce.rsc

# --- Detection / staging (mangle, forward chain) --------------------------
/ip firewall mangle
add action=add-src-to-address-list address-list="black-list attackers" \
    address-list-timeout=4w2d chain=forward comment="RDP bruteforce" \
    connection-state=new dst-port=3389 protocol=tcp \
    src-address=!192.168.0.0/16 src-address-list=rdp_stage5
add action=add-src-to-address-list address-list=rdp_stage5 \
    address-list-timeout=5m chain=forward connection-state=new dst-port=3389 \
    protocol=tcp src-address-list=rdp_stage4
add action=add-src-to-address-list address-list=rdp_stage4 \
    address-list-timeout=3m chain=forward connection-state=new dst-port=3389 \
    protocol=tcp src-address-list=rdp_stage3
add action=add-src-to-address-list address-list=rdp_stage3 \
    address-list-timeout=3m chain=forward connection-state=new dst-port=3389 \
    protocol=tcp src-address-list=rdp_stage2
add action=add-src-to-address-list address-list=rdp_stage2 \
    address-list-timeout=3m chain=forward connection-state=new dst-port=3389 \
    protocol=tcp src-address-list=rdp_stage1
add action=accept chain=forward connection-state=new dst-port=3389 \
    protocol=tcp src-address-list=RDP
add action=add-src-to-address-list address-list=rdp_stage1 \
    address-list-timeout=3m chain=forward connection-state=new dst-port=3389 \
    protocol=tcp src-address-list=!management

# --- Blocking (filter, forward chain) -------------------------------------
# Drop every packet coming from a banned attacker. Place this rule near the top
# of the forward chain so a ban takes effect immediately.
/ip firewall filter
add action=drop chain=forward comment="RDP bruteforce: drop banned attackers" \
    src-address-list="black-list attackers"
