#!/bin/sh
# Cudy WR3000 OpenWrt Setup Script
# ash-compatible, idempotent
# Usage: sh setup.sh
# Supports vless:// URI or individual parameters

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

# ===== vless:// URI parser =====
parse_vless_uri() {
    local raw="$1"
    local uri query authority hostport

    uri="${raw#vless://}"

    case "$uri" in
        *"#"*) VLESS_PROFILE_NAME="${uri##*#}"; uri="${uri%%#*}" ;;
        *) VLESS_PROFILE_NAME="" ;;
    esac
    VLESS_PROFILE_NAME=$(echo "$VLESS_PROFILE_NAME" | sed 's/%20/ /g; s/+/ /g')

    case "$uri" in
        *"?"*) query="${uri##*\?}"; authority="${uri%%\?*}" ;;
        *) query=""; authority="$uri" ;;
    esac

    VLESS_UUID="${authority%%@*}"
    hostport="${authority##*@}"
    VLESS_SERVER="${hostport%:*}"
    VLESS_PORT="${hostport##*:}"

    REALITY_PUBLIC_KEY="" ; REALITY_SHORT_ID="" ; REALITY_SNI="" ; TLS_FINGERPRINT="chrome" ; VLESS_FLOW="" ; VLESS_SECURITY="reality"
    local old_ifs="$IFS"
    IFS='&'
    for kv in $query; do
        local k="${kv%%=*}" v="${kv#*=}"
        case "$k" in
            pbk) REALITY_PUBLIC_KEY="$v" ;;
            sid) REALITY_SHORT_ID="$v" ;;
            sni) REALITY_SNI="$v" ;;
            fp) TLS_FINGERPRINT="$v" ;;
            flow) VLESS_FLOW="$v" ;;
            security) VLESS_SECURITY="$v" ;;
        esac
    done
    IFS="$old_ifs"

    [ -z "$TLS_FINGERPRINT" ] && TLS_FINGERPRINT="chrome"
    [ -z "$VLESS_PROFILE_NAME" ] && VLESS_PROFILE_NAME="$VLESS_SERVER"

    case "$VLESS_SECURITY" in
        none)
            VLESS_FLOW=""
            REALITY_PUBLIC_KEY="" ; REALITY_SHORT_ID="" ; REALITY_SNI=""
            ;;
        *)
            VLESS_SECURITY="reality"
            [ -z "$VLESS_FLOW" ] && VLESS_FLOW="xtls-rprx-vision"
            [ -z "$REALITY_SNI" ] && REALITY_SNI="www.icloud.com"
            ;;
    esac
}

# ===== Gather parameters =====

# Check if vless:// URI is provided
if [ -n "$VLESS_URI" ]; then
    log "Parsing vless:// URI..."
    parse_vless_uri "$VLESS_URI"
else
    ask "Enter vless:// URI (or press Enter for manual input): "; read VLESS_URI_INPUT
    if [ -n "$VLESS_URI_INPUT" ]; then
        parse_vless_uri "$VLESS_URI_INPUT"
    else
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
        [ -z "$TLS_FINGERPRINT" ] && TLS_FINGERPRINT="chrome"
        [ -z "$VLESS_FLOW" ] && VLESS_FLOW="xtls-rprx-vision"
        [ -z "$VLESS_PROFILE_NAME" ] && VLESS_PROFILE_NAME="$VLESS_SERVER"
    fi
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
for var in VLESS_SERVER VLESS_UUID WIFI_SSID WIFI_PASSWORD; do
    eval val=\$$var
    if [ -z "$val" ]; then
        warn "Missing required parameter: $var"
        exit 1
    fi
done
# Reality-specific params required only when security != none
if [ "$VLESS_SECURITY" != "none" ]; then
    for var in REALITY_PUBLIC_KEY REALITY_SHORT_ID; do
        eval val=\$$var
        if [ -z "$val" ]; then
            warn "Missing required parameter: $var (needed for security=$VLESS_SECURITY)"
            exit 1
        fi
    done
fi

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

# ===== 3. Deploy sing-box templates and rule sets =====
log "Deploying sing-box templates and rule sets..."
mkdir -p /etc/sing-box/templates
mkdir -p /etc/sing-box/rules

cp "$SCRIPT_DIR/configs/sing-box/templates/config_full_vpn.tpl.json" /etc/sing-box/templates/
cp "$SCRIPT_DIR/configs/sing-box/templates/config_global_except_ru.tpl.json" /etc/sing-box/templates/
cp "$SCRIPT_DIR/configs/sing-box/rules/geoip-ru.srs" /etc/sing-box/rules/
cp "$SCRIPT_DIR/configs/sing-box/rules/geosite-category-ru.srs" /etc/sing-box/rules/

# ===== 4. Create initial vless_profiles.json =====
log "Creating VLESS profiles..."
PROFILES_FILE="/etc/vless_profiles.json"
PROFILE_ID="p1"
PORT_FULL=12345
PORT_GLOBAL=12346

echo "{\"profiles\":[{\"id\":\"$PROFILE_ID\",\"name\":\"$VLESS_PROFILE_NAME\",\"server\":\"$VLESS_SERVER\",\"server_port\":$VLESS_PORT,\"uuid\":\"$VLESS_UUID\",\"security\":\"$VLESS_SECURITY\",\"public_key\":\"$REALITY_PUBLIC_KEY\",\"short_id\":\"$REALITY_SHORT_ID\",\"sni\":\"$REALITY_SNI\",\"fingerprint\":\"$TLS_FINGERPRINT\",\"flow\":\"$VLESS_FLOW\",\"port_full_vpn\":$PORT_FULL,\"port_global_except_ru\":$PORT_GLOBAL}],\"default_profile_id\":\"$PROFILE_ID\",\"next_port\":12347,\"next_id\":2}" > "$PROFILES_FILE"

# ===== 5. Generate sing-box configs from templates =====
log "Generating sing-box configs for initial profile..."

# Build security block (flow + tls) or empty for security=none
SEC_FILE="/tmp/sb_sec_block_$$"
if [ "$VLESS_SECURITY" = "none" ]; then
    printf '' > "$SEC_FILE"
else
    cat > "$SEC_FILE" << SECEOF
,
      "flow": "$VLESS_FLOW",
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_SNI",
        "utls": {
          "enabled": true,
          "fingerprint": "$TLS_FINGERPRINT"
        },
        "reality": {
          "enabled": true,
          "public_key": "$REALITY_PUBLIC_KEY",
          "short_id": "$REALITY_SHORT_ID"
        }
      }
SECEOF
fi

for mode in full_vpn global_except_ru; do
    tpl="/etc/sing-box/templates/config_${mode}.tpl.json"
    case "$mode" in
        full_vpn) listen_port="$PORT_FULL" ;;
        *) listen_port="$PORT_GLOBAL" ;;
    esac
    sed \
        -e "s|%%LISTEN_PORT%%|$listen_port|g" \
        -e "s|%%PROFILE_ID%%|$PROFILE_ID|g" \
        -e "s|%%VLESS_SERVER%%|$VLESS_SERVER|g" \
        -e "s|%%VLESS_PORT%%|$VLESS_PORT|g" \
        -e "s|%%VLESS_UUID%%|$VLESS_UUID|g" \
        "$tpl" | awk -v secfile="$SEC_FILE" '
        /%%VLESS_SECURITY_BLOCK%%/ {
            gsub(/%%VLESS_SECURITY_BLOCK%%/, "")
            printf "%s", $0
            while ((getline line < secfile) > 0) print line
            close(secfile)
            next
        }
        { print }
        ' > "/etc/sing-box/config_${mode}_${PROFILE_ID}.json"
done
rm -f "$SEC_FILE"

# ===== 6. Deploy sing-box init.d =====
log "Deploying sing-box init.d script..."
cp "$SCRIPT_DIR/scripts/init.d/sing-box" /etc/init.d/sing-box
chmod +x /etc/init.d/sing-box

# ===== 7. Deploy update-rulesets script + cron =====
log "Deploying rule set update script..."
cp "$SCRIPT_DIR/scripts/update-rulesets.sh" /etc/sing-box/update-rulesets.sh
chmod +x /etc/sing-box/update-rulesets.sh

# Add weekly cron job (Monday 4:00 AM)
CRON_LINE="0 4 * * 1 /etc/sing-box/update-rulesets.sh"
(crontab -l 2>/dev/null | grep -v "update-rulesets.sh"; echo "$CRON_LINE") | crontab -

# ===== 8. Deploy zapret config and hostlist =====
log "Deploying zapret config..."
cp "$SCRIPT_DIR/configs/zapret/config" "$ZAPRET_DIR/config"
mkdir -p "$ZAPRET_DIR/ipset"
cp "$SCRIPT_DIR/configs/zapret/zapret-hosts-user.txt" "$ZAPRET_DIR/ipset/zapret-hosts-user.txt"

# ===== 9. Zapret symlinks =====
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

# ===== 10. Deploy CGI panel =====
log "Deploying web control panel..."
mkdir -p /www/cgi-bin
cp "$SCRIPT_DIR/scripts/cgi-bin/vpn" /www/cgi-bin/vpn
chmod +x /www/cgi-bin/vpn

# Init state files
[ -f /etc/vpn_state.json ] || echo '{}' > /etc/vpn_state.json
[ -f /etc/device_names.json ] || echo '{}' > /etc/device_names.json

# ===== 11. Setup nftables + ip rule =====
log "Setting up nftables and ip rule..."
cp "$SCRIPT_DIR/configs/nftables/proxy-tproxy.sh" /etc/proxy-tproxy.sh
chmod +x /etc/proxy-tproxy.sh
sh /etc/proxy-tproxy.sh

# ===== 12. Configure Wi-Fi =====
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

# ===== 13. Configure uhttpd for CGI =====
log "Configuring uhttpd..."
uci set uhttpd.main.interpreter='.cgi=/bin/sh'
uci add_list uhttpd.main.cgi_prefix='/cgi-bin' 2>/dev/null || true
uci commit uhttpd

# ===== 14. Create boot script for nftables/ip rule =====
log "Creating boot autostart script..."
cat > /etc/init.d/proxy-routing <<'INITEOF'
#!/bin/sh /etc/rc.common

START=99
STOP=10

USE_PROCD=1

STATE_FILE="/etc/vpn_state.json"
PROFILES_FILE="/etc/vless_profiles.json"

get_all_servers() {
    grep -o '"server":"[^"]*"' "$PROFILES_FILE" | sed 's/"server":"//;s/"//' | sort -u | tr '\n' ',' | sed 's/,$//'
}

get_default_profile_id() {
    grep -o '"default_profile_id":"[^"]*"' "$PROFILES_FILE" | head -1 | sed 's/.*"default_profile_id":"//;s/"//'
}

get_profile_port() {
    local pid="$1" mode="$2" key
    case "$mode" in
        full_vpn) key="port_full_vpn" ;;
        *) key="port_global_except_ru" ;;
    esac
    grep -o "\"id\":\"$pid\"[^}]*" "$PROFILES_FILE" | grep -o "\"$key\":[0-9]*" | head -1 | sed "s/\"$key\"://"
}

start_service() {
    ALL_SERVERS=$(get_all_servers)
    [ -z "$ALL_SERVERS" ] && { logger -t proxy-routing "No VPN servers found, aborting"; return 1; }

    VPN_EXCLUDE="10.0.0.0/8, 127.0.0.0/8, 192.168.0.0/16, $ALL_SERVERS"

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
    ALL_SERVERS=$(get_all_servers)
    VPN_EXCLUDE="10.0.0.0/8, 127.0.0.0/8, 192.168.0.0/16"
    [ -n "$ALL_SERVERS" ] && VPN_EXCLUDE="$VPN_EXCLUDE, $ALL_SERVERS"

    DEFAULT_PID=$(get_default_profile_id)

    [ -f "$STATE_FILE" ] || {
        add_catchall
        return 0
    }

    grep -oE '"[0-9a-f:]{17}":\{[^}]*\}' "$STATE_FILE" | while IFS= read -r entry; do
        mac=$(echo "$entry" | grep -oE '[0-9a-f:]{17}')
        vpn_val=$(echo "$entry" | grep -o '"vpn":[a-z]*' | cut -d: -f2)
        zapret_val=$(echo "$entry" | grep -o '"zapret":[a-z]*' | cut -d: -f2)
        routing=$(echo "$entry" | grep -o '"routing":"[^"]*"' | cut -d'"' -f4)
        profile_id=$(echo "$entry" | grep -o '"profile_id":"[^"]*"' | cut -d'"' -f4)

        [ -z "$profile_id" ] && profile_id="$DEFAULT_PID"

        port=$(get_profile_port "$profile_id" "$routing")
        [ -z "$port" ] && {
            case "$routing" in
                global_except_ru) port=12346 ;;
                *) port=12345 ;;
            esac
        }

        if [ "$vpn_val" = "true" ]; then
            nft add rule ip proxy_tproxy prerouting \
                iifname "br-lan" ether saddr "$mac" \
                ip daddr != "{ $VPN_EXCLUDE }" \
                meta l4proto tcp tproxy to :$port meta mark set 0x1 accept 2>/dev/null
            nft add rule ip proxy_tproxy prerouting \
                iifname "br-lan" ether saddr "$mac" \
                ip daddr != "{ $VPN_EXCLUDE }" \
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
    ALL_SERVERS=$(get_all_servers)
    VPN_EXCLUDE="10.0.0.0/8, 127.0.0.0/8, 192.168.0.0/16"
    [ -n "$ALL_SERVERS" ] && VPN_EXCLUDE="$VPN_EXCLUDE, $ALL_SERVERS"

    DEFAULT_PID=$(get_default_profile_id)

    # Auto-fix: if no device uses the current default, pick the most used profile
    if [ -f "$STATE_FILE" ] && ! grep -q "\"profile_id\":\"$DEFAULT_PID\"" "$STATE_FILE"; then
        MOST_USED=$(grep -o '"profile_id":"[^"]*"' "$STATE_FILE" | sort | uniq -c | sort -rn | head -1 | grep -o '"[^"]*"$' | tr -d '"')
        if [ -n "$MOST_USED" ] && [ "$MOST_USED" != "$DEFAULT_PID" ]; then
            sed -i "s/\"default_profile_id\":\"[^\"]*\"/\"default_profile_id\":\"$MOST_USED\"/" "$PROFILES_FILE"
            DEFAULT_PID="$MOST_USED"
            logger -t proxy-routing "Auto-switched default profile to $DEFAULT_PID"
        fi
    fi

    DEFAULT_VPN_PORT=$(get_profile_port "$DEFAULT_PID" "global_except_ru")
    [ -z "$DEFAULT_VPN_PORT" ] && DEFAULT_VPN_PORT=12346

    nft add rule ip proxy_tproxy prerouting \
        iifname "br-lan" \
        ip daddr != "{ $VPN_EXCLUDE }" \
        meta l4proto tcp tproxy to :$DEFAULT_VPN_PORT meta mark set 0x1 accept 2>/dev/null
    nft add rule ip proxy_tproxy prerouting \
        iifname "br-lan" \
        ip daddr != "{ $VPN_EXCLUDE }" \
        meta l4proto udp tproxy to :$DEFAULT_VPN_PORT meta mark set 0x1 accept 2>/dev/null
    logger -t proxy-routing "Catch-all VPN (port $DEFAULT_VPN_PORT, global_except_ru) enabled"

    # Catch-all: zapret OFF for unknown devices
    nft add rule inet proxy_route forward_zapret iifname "br-lan" return 2>/dev/null
    logger -t proxy-routing "Catch-all zapret OFF (return) enabled"
}
INITEOF
chmod +x /etc/init.d/proxy-routing

# ===== 15. Enable and start services =====
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
