#!/bin/sh
# Cudy WR3000 OpenWrt Setup Script
# ash-compatible, idempotent
# Usage: sh setup.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ===== Colors =====
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { printf "${GREEN}[+]${NC} %s\n" "$1"; }
warn() { printf "${RED}[!]${NC} %s\n" "$1"; }
ask() { printf "${CYAN}[?]${NC} %s" "$1"; }

# ===== Gather parameters =====
if [ -z "$VLESS_SERVER" ]; then
    ask "VLESS server IP: "; read VLESS_SERVER
fi
if [ -z "$VLESS_PORT" ]; then
    ask "VLESS port [42832]: "; read VLESS_PORT
    [ -z "$VLESS_PORT" ] && VLESS_PORT="42832"
fi
if [ -z "$VLESS_UUID" ]; then
    ask "VLESS UUID: "; read VLESS_UUID
fi
if [ -z "$REALITY_PUBLIC_KEY" ]; then
    ask "Reality public key: "; read REALITY_PUBLIC_KEY
fi
if [ -z "$REALITY_SHORT_ID" ]; then
    ask "Reality short_id: "; read REALITY_SHORT_ID
fi
if [ -z "$REALITY_SNI" ]; then
    ask "Reality SNI [www.icloud.com]: "; read REALITY_SNI
    [ -z "$REALITY_SNI" ] && REALITY_SNI="www.icloud.com"
fi
if [ -z "$WIFI_SSID" ]; then
    ask "Wi-Fi SSID: "; read WIFI_SSID
fi
if [ -z "$WIFI_PASSWORD" ]; then
    ask "Wi-Fi password: "; read WIFI_PASSWORD
fi
if [ -z "$WIFI_SSID_5G" ]; then
    ask "Wi-Fi 5GHz SSID [${WIFI_SSID}_5G]: "; read WIFI_SSID_5G
    [ -z "$WIFI_SSID_5G" ] && WIFI_SSID_5G="${WIFI_SSID}_5G"
fi

# Validate required params
for var in VLESS_SERVER VLESS_UUID REALITY_PUBLIC_KEY REALITY_SHORT_ID WIFI_SSID WIFI_PASSWORD; do
    eval val=\$$var
    if [ -z "$val" ]; then
        warn "Missing required parameter: $var"
        exit 1
    fi
done

# ===== 1. Install packages =====
log "Installing packages..."
opkg update
opkg install sing-box kmod-nft-tproxy kmod-nf-tproxy kmod-inet-diag ip-full curl git-http

# ===== 2. Clone zapret to USB =====
ZAPRET_DIR="/mnt/usb/zapret2"
if [ ! -d "$ZAPRET_DIR/.git" ]; then
    log "Cloning zapret to $ZAPRET_DIR..."
    if [ -d "$ZAPRET_DIR" ]; then
        warn "$ZAPRET_DIR exists but is not a git repo, backing up..."
        mv "$ZAPRET_DIR" "${ZAPRET_DIR}.bak.$(date +%s)"
    fi
    git clone https://github.com/bol-van/zapret "$ZAPRET_DIR"
else
    log "zapret already cloned, pulling updates..."
    cd "$ZAPRET_DIR" && git pull || true
    cd "$SCRIPT_DIR"
fi

# ===== 3. Deploy sing-box configs =====
log "Deploying sing-box configs..."
mkdir -p /etc/sing-box

for tpl in config_full_vpn.json config_global_except_ru.json; do
    sed \
        -e "s|%%VLESS_SERVER%%|$VLESS_SERVER|g" \
        -e "s|%%VLESS_PORT%%|$VLESS_PORT|g" \
        -e "s|%%VLESS_UUID%%|$VLESS_UUID|g" \
        -e "s|%%REALITY_PUBLIC_KEY%%|$REALITY_PUBLIC_KEY|g" \
        -e "s|%%REALITY_SHORT_ID%%|$REALITY_SHORT_ID|g" \
        -e "s|%%REALITY_SNI%%|$REALITY_SNI|g" \
        "$SCRIPT_DIR/configs/sing-box/$tpl" > "/etc/sing-box/$tpl"
done

# ===== 4. Deploy sing-box init.d =====
log "Deploying sing-box init.d script..."
cp "$SCRIPT_DIR/scripts/init.d/sing-box" /etc/init.d/sing-box
chmod +x /etc/init.d/sing-box

# ===== 5. Deploy zapret config and hostlist =====
log "Deploying zapret config..."
cp "$SCRIPT_DIR/configs/zapret/config" "$ZAPRET_DIR/config"
mkdir -p "$ZAPRET_DIR/ipset"
cp "$SCRIPT_DIR/configs/zapret/zapret-hosts-user.txt" "$ZAPRET_DIR/ipset/zapret-hosts-user.txt"

# ===== 6. Zapret symlinks =====
log "Setting up zapret symlinks..."
if [ -f "$ZAPRET_DIR/init.d/sysv/zapret2" ]; then
    ln -sf "$ZAPRET_DIR/init.d/sysv/zapret2" /etc/init.d/zapret2
    chmod +x "$ZAPRET_DIR/init.d/sysv/zapret2"
elif [ -f "$ZAPRET_DIR/init.d/sysv/zapret" ]; then
    ln -sf "$ZAPRET_DIR/init.d/sysv/zapret" /etc/init.d/zapret2
    chmod +x "$ZAPRET_DIR/init.d/sysv/zapret"
fi

[ -f "$ZAPRET_DIR/init.d/openwrt/firewall.zapret2" ] && \
    ln -sf "$ZAPRET_DIR/init.d/openwrt/firewall.zapret2" /etc/firewall.zapret2

mkdir -p /etc/hotplug.d/iface
[ -f "$ZAPRET_DIR/init.d/openwrt/90-zapret2" ] && \
    ln -sf "$ZAPRET_DIR/init.d/openwrt/90-zapret2" /etc/hotplug.d/iface/90-zapret2

# ===== 7. Deploy CGI panel =====
log "Deploying web control panel..."
mkdir -p /www/cgi-bin
cp "$SCRIPT_DIR/scripts/cgi-bin/vpn" /www/cgi-bin/vpn
chmod +x /www/cgi-bin/vpn

# Init state files
[ -f /etc/vpn_state.json ] || echo '{}' > /etc/vpn_state.json
[ -f /etc/device_names.json ] || echo '{}' > /etc/device_names.json

# ===== 8. Setup nftables + ip rule =====
log "Setting up nftables and ip rule..."
cp "$SCRIPT_DIR/configs/nftables/proxy-tproxy.sh" /etc/proxy-tproxy.sh
chmod +x /etc/proxy-tproxy.sh
sh /etc/proxy-tproxy.sh

# ===== 9. Configure Wi-Fi =====
log "Configuring Wi-Fi..."
uci set wireless.radio0.disabled='0'
uci set wireless.default_radio0.ssid="$WIFI_SSID"
uci set wireless.default_radio0.encryption='psk2'
uci set wireless.default_radio0.key="$WIFI_PASSWORD"

uci set wireless.radio1.disabled='0'
uci set wireless.default_radio1.ssid="$WIFI_SSID_5G"
uci set wireless.default_radio1.encryption='sae-mixed'
uci set wireless.default_radio1.key="$WIFI_PASSWORD"

uci commit wireless

# ===== 10. Configure uhttpd for CGI =====
log "Configuring uhttpd..."
uci set uhttpd.main.interpreter='.cgi=/bin/sh'
uci add_list uhttpd.main.cgi_prefix='/cgi-bin' 2>/dev/null || true
uci commit uhttpd

# ===== 11. Create boot script for nftables/ip rule =====
log "Creating boot autostart script..."
cat > /etc/init.d/proxy-routing <<'INITEOF'
#!/bin/sh /etc/rc.common

START=99
STOP=10

USE_PROCD=1

STATE_FILE="/etc/vpn_state.json"
TPROXY_PORT="12345"
DEFAULT_VPN_PORT="12346"

start_service() {
    VPN_SERVER=$(grep -oE '"server"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' /etc/sing-box/config_full_vpn.json 2>/dev/null | head -1 | sed 's/.*"server"[[:space:]]*:[[:space:]]*"//; s/"//')
    [ -z "$VPN_SERVER" ] && { logger -t proxy-routing "No VPN_SERVER found, aborting"; return 1; }

    # Create nftables tables and chains
    nft add table ip proxy_tproxy 2>/dev/null
    nft add chain ip proxy_tproxy prerouting '{ type filter hook prerouting priority mangle; policy accept; }' 2>/dev/null
    nft add table inet proxy_route 2>/dev/null
    nft add chain inet proxy_route forward_zapret '{ type filter hook forward priority filter; policy accept; }' 2>/dev/null

    # Set up routing for tproxy
    ip rule del fwmark 1 lookup 100 2>/dev/null
    ip rule add fwmark 1 lookup 100
    ip route replace local 0.0.0.0/0 dev lo table 100

    # DHCP must bypass tproxy (broadcast 255.255.255.255 not in excluded ranges)
    nft insert rule ip proxy_tproxy prerouting iifname "br-lan" udp dport '{ 67, 68 }' accept 2>/dev/null

    # Restore state from JSON
    restore_state

    logger -t proxy-routing "proxy-routing started, state restored"
}

stop_service() {
    nft flush chain ip proxy_tproxy prerouting 2>/dev/null
    nft flush chain inet proxy_route forward_zapret 2>/dev/null
    ip rule del fwmark 1 lookup 100 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null
    logger -t proxy-routing "proxy-routing stopped"
}

restore_state() {
    VPN_SERVER=$(grep -oE '"server"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' /etc/sing-box/config_full_vpn.json 2>/dev/null | head -1 | sed 's/.*"server"[[:space:]]*:[[:space:]]*"//; s/"//')

    [ -f "$STATE_FILE" ] || {
        add_catchall
        return 0
    }

    grep -oE '"[0-9a-f:]{17}":\{[^}]*\}' "$STATE_FILE" | while IFS= read -r entry; do
        mac=$(echo "$entry" | grep -oE '[0-9a-f:]{17}')
        vpn_val=$(echo "$entry" | grep -o '"vpn":[a-z]*' | cut -d: -f2)
        zapret_val=$(echo "$entry" | grep -o '"zapret":[a-z]*' | cut -d: -f2)
        routing=$(echo "$entry" | grep -o '"routing":"[^"]*"' | cut -d'"' -f4)

        case "$routing" in
            global_except_ru) port=12346 ;;
            *) port=12345 ;;
        esac

        if [ "$vpn_val" = "true" ]; then
            nft add rule ip proxy_tproxy prerouting \
                iifname "br-lan" ether saddr "$mac" \
                ip daddr != "{ 10.0.0.0/8, 127.0.0.0/8, 192.168.0.0/16, $VPN_SERVER }" \
                meta l4proto tcp tproxy to :$port meta mark set 0x1 accept 2>/dev/null
            nft add rule ip proxy_tproxy prerouting \
                iifname "br-lan" ether saddr "$mac" \
                ip daddr != "{ 10.0.0.0/8, 127.0.0.0/8, 192.168.0.0/16, $VPN_SERVER }" \
                meta l4proto udp tproxy to :$port meta mark set 0x1 accept 2>/dev/null
        elif [ "$vpn_val" = "false" ]; then
            nft add rule ip proxy_tproxy prerouting \
                iifname "br-lan" ether saddr "$mac" accept 2>/dev/null
        fi

        if [ "$zapret_val" = "true" ]; then
            nft insert rule inet proxy_route forward_zapret ether saddr "$mac" accept 2>/dev/null
        fi
    done

    add_catchall
}

add_catchall() {
    VPN_SERVER=$(grep -oE '"server"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' /etc/sing-box/config_full_vpn.json 2>/dev/null | head -1 | sed 's/.*"server"[[:space:]]*:[[:space:]]*"//; s/"//')

    nft add rule ip proxy_tproxy prerouting \
        iifname "br-lan" \
        ip daddr != "{ 10.0.0.0/8, 127.0.0.0/8, 192.168.0.0/16, $VPN_SERVER }" \
        meta l4proto tcp tproxy to :$DEFAULT_VPN_PORT meta mark set 0x1 accept 2>/dev/null
    nft add rule ip proxy_tproxy prerouting \
        iifname "br-lan" \
        ip daddr != "{ 10.0.0.0/8, 127.0.0.0/8, 192.168.0.0/16, $VPN_SERVER }" \
        meta l4proto udp tproxy to :$DEFAULT_VPN_PORT meta mark set 0x1 accept 2>/dev/null
    logger -t proxy-routing "Catch-all VPN (port $DEFAULT_VPN_PORT, global_except_ru) enabled"

    # Catch-all: zapret OFF for unknown devices
    nft add rule inet proxy_route forward_zapret iifname "br-lan" return 2>/dev/null
    logger -t proxy-routing "Catch-all zapret OFF (return) enabled"
}
INITEOF
chmod +x /etc/init.d/proxy-routing

# ===== 12. Enable and start services =====
log "Enabling and starting services..."

/etc/init.d/proxy-routing enable

/etc/init.d/sing-box enable
/etc/init.d/sing-box start || warn "sing-box failed to start, check configs"

if [ -x /etc/init.d/zapret2 ]; then
    /etc/init.d/zapret2 enable
    /etc/init.d/zapret2 start || warn "zapret2 failed to start"
else
    warn "zapret2 init script not found, skipping"
fi

/etc/init.d/uhttpd restart

wifi reload

log "Setup complete!"
log "Web panel: http://192.168.2.1/cgi-bin/vpn"
log "Connect to Wi-Fi: $WIFI_SSID / $WIFI_SSID_5G"
