# Dual-WAN (dual-ISP) health check and failover helper.
#
# Pings a reachable host through each uplink. If an uplink loses connectivity
# (zero successful replies), its marked connections are flushed from the
# connection tracking table so that traffic re-routes through the other ISP.
#
# Intended to run periodically from the scheduler, e.g.:
#   /system scheduler
#   add name=check-isp interval=30s on-event="/import file-name=check-isp.rsc"
#
# Requirements:
#   - ether1 / ether2 are the ISP1 / ISP2 uplinks (adjust below if different).
#   - Mangle rules mark per-ISP connections as con-isp1 / con-isp2.

# --- Settings -------------------------------------------------------------
:local PingCount 5;            # number of echo requests per check
:local Isp1Iface "ether1";     # ISP1 uplink interface
:local Isp2Iface "ether2";     # ISP2 uplink interface
:local CheckIp1 77.88.8.8;     # host probed through ISP1
:local CheckIp2 77.88.8.1;     # host probed through ISP2

# --- Probe each uplink (number of successful replies, 0 = down) ----------
:local isp1 [/ping $CheckIp1 count=$PingCount interface=$Isp1Iface];
:local isp2 [/ping $CheckIp2 count=$PingCount interface=$Isp2Iface];

# --- ISP1 failover --------------------------------------------------------
:if ($isp1 = 0) do={
    :log warning "ISP1 down";
    :delay 2s;
    # Flush ISP1-marked connections so sessions re-route via ISP2.
    /ip firewall connection remove [find where connection-mark="con-isp1"];
    :delay 2s;
    :log warning "ISP1 connection reset";
}

# --- ISP2 failover --------------------------------------------------------
:if ($isp2 = 0) do={
    :log warning "ISP2 down";
    :delay 2s;
    # Flush ISP2-marked connections so sessions re-route via ISP1.
    /ip firewall connection remove [find where connection-mark="con-isp2"];
    :delay 2s;
    :log warning "ISP2 connection reset";
}
