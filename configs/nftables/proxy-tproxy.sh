#!/bin/sh
# Создание nftables таблиц для tproxy и zapret per-device control
# Вызывается из setup.sh и из автозапуска после ребута

LAN_IFACE=$(cat /etc/vpn_lan_iface 2>/dev/null || echo "br-lan")

# ip rule и route для tproxy
ip rule show | grep -q "fwmark 0x1 lookup 100" || ip rule add fwmark 0x1 lookup 100
ip route show table 100 2>/dev/null | grep -q "local default" || ip route add local default dev lo table 100

# Таблица tproxy для sing-box
nft list table ip proxy_tproxy >/dev/null 2>&1 || nft add table ip proxy_tproxy
nft list chain ip proxy_tproxy prerouting >/dev/null 2>&1 || \
    nft add chain ip proxy_tproxy prerouting '{ type filter hook prerouting priority mangle; policy accept; }'

# DHCP must bypass tproxy (broadcast 255.255.255.255 not in excluded ranges)
nft list chain ip proxy_tproxy prerouting 2>/dev/null | grep -q 'udp dport { 67, 68 }' || \
    nft insert rule ip proxy_tproxy prerouting iifname "$LAN_IFACE" udp dport '{ 67, 68 }' accept

# Таблица для per-device zapret control
nft list table inet proxy_route >/dev/null 2>&1 || nft add table inet proxy_route
nft list chain inet proxy_route forward_zapret >/dev/null 2>&1 || \
    nft add chain inet proxy_route forward_zapret '{ type filter hook forward priority filter; policy accept; }'

# Restore kill switch if enabled
if [ "$(cat /etc/vpn_killswitch 2>/dev/null)" = "1" ]; then
    nft add rule ip proxy_tproxy prerouting \
        iifname "$LAN_IFACE" \
        ip daddr != "{ 10.0.0.0/8, 127.0.0.0/8, 192.168.0.0/16 }" \
        drop comment '"killswitch"' 2>/dev/null
fi
