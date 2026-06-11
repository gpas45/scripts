:local PingCount 5;
:local CheckIp1 77.88.8.8;
:local CheckIp2 77.88.8.1;
:local isp1 [/ping $CheckIp1 count=$PingCount interface="ether1"];
:local isp2 [/ping $CheckIp2 count=$PingCount interface="ether2"];

:if ($isp1=0) do={
:delay 2
:log warning "ISP1 down";
/ip firewall connection remove [ find where connection-mark="con-isp1"];
:delay 2
:log warning "ISP1 connection reset";
}
:if ($isp2=0) do={
:delay 2
:log warning "ISP2 down";
/ip firewall connection remove [ find where connection-mark="con-isp2"];
:delay 2
:log warning "ISP2 connection reset";
}
