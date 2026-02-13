#!/bin/sh
# OpenWrt VPN Setup Script (universal)
# ash-compatible, idempotent
# Usage: sh setup.sh
# Supports vless:// URI or individual parameters

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ===== Detect LAN interface and router IP =====
LAN_IFACE=$(uci get network.lan.device 2>/dev/null || echo "br-lan")
ROUTER_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo "192.168.1.1")
echo "$LAN_IFACE" > /etc/vpn_lan_iface

# ===== Colors =====
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { printf "${GREEN}[+]${NC} %s\n" "$1"; }
warn() { printf "${RED}[!]${NC} %s\n" "$1"; }
ask() { printf "${CYAN}[?]${NC} %s" "$1"; }

# Copy file and strip Windows line endings (CRLF → LF)
deploy() { cp "$1" "$2" && sed -i 's/\r$//' "$2"; }

# ===== Disk space check =====
check_space() {
    local required_mb="$1"
    local target="$2"  # mount point to check, e.g. / or /mnt/usb
    local avail_kb
    avail_kb=$(df "$target" 2>/dev/null | awk 'NR==2{print $4}')
    [ -z "$avail_kb" ] && return 0  # can't determine, proceed
    local avail_mb=$((avail_kb / 1024))
    if [ "$avail_mb" -lt "$required_mb" ]; then
        warn "Not enough space on $target: ${avail_mb}MB available, ${required_mb}MB required"
        return 1
    fi
    log "Space OK: ${avail_mb}MB available on $target (need ${required_mb}MB)"
    return 0
}

# ===== Setup mode selection =====
# Can be overridden via env: SETUP_MODE=full|vpn-only|full-git
if [ -z "$SETUP_MODE" ]; then
    echo ""
    echo "=== Installation variants ==="
    echo "  1) full       - VPN + DPI bypass (zapret)  [~18 MB]  (recommended)"
    echo "  2) vpn-only   - VPN only, no zapret        [~15 MB]"
    echo "  3) full-git   - VPN + zapret via git clone  [~48 MB]"
    echo ""
    ask "Select variant [1]: "; read MODE_CHOICE
    case "$MODE_CHOICE" in
        2) SETUP_MODE="vpn-only" ;;
        3) SETUP_MODE="full-git" ;;
        *) SETUP_MODE="full" ;;
    esac
fi
log "Setup mode: $SETUP_MODE"

# Determine space requirement
case "$SETUP_MODE" in
    vpn-only)   REQUIRED_MB=20 ;;
    full-git)   REQUIRED_MB=55 ;;
    *)          REQUIRED_MB=25 ;;
esac

# Check space on target filesystem
if mount | grep -q '/mnt/usb' && [ -w /mnt/usb ]; then
    INSTALL_TARGET="/mnt/usb"
else
    INSTALL_TARGET="/"
fi

if ! check_space "$REQUIRED_MB" "$INSTALL_TARGET"; then
    warn "Insufficient disk space for '$SETUP_MODE' variant."
    warn "Options: use a smaller variant, free space, or plug in a USB drive."
    exit 1
fi

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

# Base packages (always needed)
opkg install sing-box kmod-nft-tproxy kmod-nf-tproxy kmod-inet-diag ip-full curl

# Git only needed for full-git mode
if [ "$SETUP_MODE" = "full-git" ]; then
    opkg install git-http
fi

# ===== 2. Install zapret (conditional on SETUP_MODE) =====
if [ "$SETUP_MODE" != "vpn-only" ]; then
    # Determine zapret directory
    if mount | grep -q '/mnt/usb' && [ -w /mnt/usb ]; then
        ZAPRET_DIR="/mnt/usb/zapret2"
    else
        ZAPRET_DIR="/opt/zapret"
        mkdir -p /opt
    fi
    echo "$ZAPRET_DIR" > /etc/vpn_zapret_dir

    if [ "$SETUP_MODE" = "full-git" ]; then
        # Git clone (supports git pull updates later)
        if [ ! -d "$ZAPRET_DIR/.git" ]; then
            log "Cloning zapret to $ZAPRET_DIR..."
            [ -d "$ZAPRET_DIR" ] && mv "$ZAPRET_DIR" "${ZAPRET_DIR}.bak.$(date +%s)"
            git clone https://github.com/bol-van/zapret "$ZAPRET_DIR"
        else
            log "zapret already cloned, pulling updates..."
            cd "$ZAPRET_DIR" && git pull || true
            cd "$SCRIPT_DIR"
        fi
    else
        # Tarball download (saves ~30 MB, no git needed)
        if [ ! -d "$ZAPRET_DIR" ] || [ ! -f "$ZAPRET_DIR/init.d/sysv/zapret" ]; then
            log "Downloading zapret tarball to $ZAPRET_DIR..."
            [ -d "$ZAPRET_DIR" ] && mv "$ZAPRET_DIR" "${ZAPRET_DIR}.bak.$(date +%s)"
            mkdir -p "$ZAPRET_DIR"
            curl -sL "https://github.com/bol-van/zapret/archive/refs/heads/master.tar.gz" | \
                tar xz -C "$ZAPRET_DIR" --strip-components=1
        else
            log "zapret already present at $ZAPRET_DIR, skipping download"
        fi
    fi
else
    log "Skipping zapret (vpn-only mode)"
    # Write empty marker so other scripts know zapret is not installed
    echo "" > /etc/vpn_zapret_dir
fi

# ===== 3. Deploy sing-box templates and rule sets =====
log "Deploying sing-box templates and rule sets..."
mkdir -p /etc/sing-box/templates
mkdir -p /etc/sing-box/rules

deploy "$SCRIPT_DIR/configs/sing-box/templates/config_full_vpn.tpl.json" /etc/sing-box/templates/config_full_vpn.tpl.json
deploy "$SCRIPT_DIR/configs/sing-box/templates/config_global_except_ru.tpl.json" /etc/sing-box/templates/config_global_except_ru.tpl.json
cp "$SCRIPT_DIR/configs/sing-box/rules/geoip-ru.srs" /etc/sing-box/rules/
cp "$SCRIPT_DIR/configs/sing-box/rules/geosite-category-ru.srs" /etc/sing-box/rules/

# ===== 4. Create initial vless_profiles.json =====
PROFILES_FILE="/etc/vless_profiles.json"
PROFILE_ID="p1"
PORT_FULL=12345
PORT_GLOBAL=12346

if [ -f "$PROFILES_FILE" ] && grep -q '"profiles":\[' "$PROFILES_FILE"; then
    log "Profiles file exists, keeping existing profiles"
else
    log "Creating VLESS profiles..."
    echo "{\"profiles\":[{\"id\":\"$PROFILE_ID\",\"name\":\"$VLESS_PROFILE_NAME\",\"server\":\"$VLESS_SERVER\",\"server_port\":$VLESS_PORT,\"uuid\":\"$VLESS_UUID\",\"security\":\"$VLESS_SECURITY\",\"public_key\":\"$REALITY_PUBLIC_KEY\",\"short_id\":\"$REALITY_SHORT_ID\",\"sni\":\"$REALITY_SNI\",\"fingerprint\":\"$TLS_FINGERPRINT\",\"flow\":\"$VLESS_FLOW\",\"port_full_vpn\":$PORT_FULL,\"port_global_except_ru\":$PORT_GLOBAL}],\"default_profile_id\":\"$PROFILE_ID\",\"next_port\":12347,\"next_id\":2}" > "$PROFILES_FILE"
fi

# ===== 5. Initialize custom rules (idempotent) =====
CUSTOM_RULES_FILE="/etc/sing-box/custom_rules.json"
[ -f "$CUSTOM_RULES_FILE" ] || echo '{"direct":[],"vpn":[]}' > "$CUSTOM_RULES_FILE"

# ===== Custom rules builder =====
build_custom_rules_file() {
    local mode="$1" route_out="$2" dns_out="$3"
    local rules_file="$CUSTOM_RULES_FILE"
    > "$route_out"; > "$dns_out"
    [ -f "$rules_file" ] || return 0

    local direct=$(grep -o '"direct":\[[^]]*\]' "$rules_file" | sed 's/"direct":\[//;s/\]$//' | tr -d ' ')
    local vpn=$(grep -o '"vpn":\[[^]]*\]' "$rules_file" | sed 's/"vpn":\[//;s/\]$//' | tr -d ' ')

    case "$mode" in
        global_except_ru)
            [ -n "$direct" ] && {
                echo "      {\"domain_suffix\":[$direct],\"outbound\":\"direct\"}," >> "$route_out"
                echo "      {\"domain_suffix\":[$direct],\"server\":\"dns-direct\"}," >> "$dns_out"
            }
            [ -n "$vpn" ] && {
                echo "      {\"domain_suffix\":[$vpn],\"outbound\":\"vless-out\"}," >> "$route_out"
                echo "      {\"domain_suffix\":[$vpn],\"server\":\"dns-remote\"}," >> "$dns_out"
            }
            ;;
        full_vpn)
            [ -n "$direct" ] && {
                echo "      ,{\"domain_suffix\":[$direct],\"outbound\":\"direct\"}" >> "$route_out"
                echo "      ,{\"domain_suffix\":[$direct],\"server\":\"dns-direct\"}" >> "$dns_out"
            }
            ;;
    esac
}

# ===== 6. Generate sing-box configs from templates =====
log "Generating sing-box configs..."

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

    cr_route="/tmp/sb_custom_route_$$"
    cr_dns="/tmp/sb_custom_dns_$$"
    build_custom_rules_file "$mode" "$cr_route" "$cr_dns"

    sed \
        -e "s|%%LISTEN_PORT%%|$listen_port|g" \
        -e "s|%%PROFILE_ID%%|$PROFILE_ID|g" \
        -e "s|%%VLESS_SERVER%%|$VLESS_SERVER|g" \
        -e "s|%%VLESS_PORT%%|$VLESS_PORT|g" \
        -e "s|%%VLESS_UUID%%|$VLESS_UUID|g" \
        "$tpl" | awk -v secfile="$SEC_FILE" -v crroute="$cr_route" -v crdns="$cr_dns" '
        /%%VLESS_SECURITY_BLOCK%%/ {
            gsub(/%%VLESS_SECURITY_BLOCK%%/, "")
            printf "%s", $0
            while ((getline line < secfile) > 0) print line
            close(secfile)
            next
        }
        /%%CUSTOM_ROUTE_RULES%%/ {
            while ((getline line < crroute) > 0) print line
            close(crroute)
            next
        }
        /%%CUSTOM_DNS_RULES%%/ {
            while ((getline line < crdns) > 0) print line
            close(crdns)
            next
        }
        { print }
        ' > "/etc/sing-box/config_${mode}_${PROFILE_ID}.json"
    rm -f "$cr_route" "$cr_dns"
done
rm -f "$SEC_FILE"

# ===== 7. Deploy sing-box init.d =====
log "Deploying sing-box init.d script..."
deploy "$SCRIPT_DIR/scripts/init.d/sing-box" /etc/init.d/sing-box
chmod +x /etc/init.d/sing-box

# ===== 8. Deploy update-rulesets script + cron =====
log "Deploying rule set update script..."
deploy "$SCRIPT_DIR/scripts/update-rulesets.sh" /etc/sing-box/update-rulesets.sh
chmod +x /etc/sing-box/update-rulesets.sh

# Add weekly cron job (Monday 4:00 AM)
CRON_LINE="0 4 * * 1 /etc/sing-box/update-rulesets.sh"
(crontab -l 2>/dev/null | grep -v "update-rulesets.sh"; echo "$CRON_LINE") | crontab -

# ===== 9. Deploy zapret config and hostlist =====
if [ "$SETUP_MODE" != "vpn-only" ]; then
    log "Deploying zapret config..."
    deploy "$SCRIPT_DIR/configs/zapret/config" "$ZAPRET_DIR/config"
    mkdir -p "$ZAPRET_DIR/ipset"
    deploy "$SCRIPT_DIR/configs/zapret/zapret-hosts-user.txt" "$ZAPRET_DIR/ipset/zapret-hosts-user.txt"
fi

# ===== 10. Zapret symlinks =====
if [ "$SETUP_MODE" != "vpn-only" ]; then
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
fi

# ===== 11. Deploy CGI panel =====
log "Deploying web control panel..."
mkdir -p /www/cgi-bin
deploy "$SCRIPT_DIR/scripts/cgi-bin/vpn" /www/cgi-bin/vpn
chmod +x /www/cgi-bin/vpn

# Init state files
[ -f /etc/vpn_state.json ] || echo '{}' > /etc/vpn_state.json
[ -f /etc/device_names.json ] || echo '{}' > /etc/device_names.json

# ===== 12. Setup nftables + ip rule =====
log "Setting up nftables and ip rule..."
deploy "$SCRIPT_DIR/configs/nftables/proxy-tproxy.sh" /etc/proxy-tproxy.sh
chmod +x /etc/proxy-tproxy.sh
sh /etc/proxy-tproxy.sh

# ===== 13. Configure Wi-Fi =====
log "Configuring Wi-Fi..."

# Detect radio bands dynamically (supports 2/3+ radio devices like GL-MT6000)
RADIO_24="" ; RADIO_5=""
for radio in $(uci show wireless 2>/dev/null | grep '=wifi-device' | cut -d. -f2 | cut -d= -f1); do
    band=$(uci get "wireless.$radio.band" 2>/dev/null)
    case "$band" in
        2g) RADIO_24="$radio" ;;
        5g) [ -z "$RADIO_5" ] && RADIO_5="$radio" ;;
    esac
done
# Fallback to legacy numbering
[ -z "$RADIO_24" ] && RADIO_24="radio0"
[ -z "$RADIO_5" ] && RADIO_5="radio1"

uci set "wireless.$RADIO_24.disabled=0"
uci set "wireless.default_$RADIO_24.ssid=$WIFI_SSID"
uci set "wireless.default_$RADIO_24.encryption=psk2"
uci set "wireless.default_$RADIO_24.key=$WIFI_PASSWORD"

uci set "wireless.$RADIO_5.disabled=0"
uci set "wireless.default_$RADIO_5.ssid=$WIFI_SSID_5G"
uci set "wireless.default_$RADIO_5.encryption=sae-mixed"
uci set "wireless.default_$RADIO_5.key=$WIFI_PASSWORD"

uci commit wireless

# ===== 14. Configure uhttpd for CGI =====
log "Configuring uhttpd..."
# Remove duplicate cgi_prefix entries, then add once
uci delete uhttpd.main.cgi_prefix 2>/dev/null || true
uci add_list uhttpd.main.cgi_prefix='/cgi-bin'
uci commit uhttpd

# ===== 15. Create boot script for nftables/ip rule =====
log "Creating boot autostart script..."
cat > /etc/init.d/proxy-routing <<'INITEOF'
#!/bin/sh /etc/rc.common

START=99
STOP=10

USE_PROCD=1

STATE_FILE="/etc/vpn_state.json"
PROFILES_FILE="/etc/vless_profiles.json"
LAN_IFACE=$(cat /etc/vpn_lan_iface 2>/dev/null || echo "br-lan")

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
    nft insert rule ip proxy_tproxy prerouting iifname "$LAN_IFACE" udp dport '{ 67, 68 }' accept 2>/dev/null

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
                iifname "$LAN_IFACE" ether saddr "$mac" \
                ip daddr != "{ $VPN_EXCLUDE }" \
                meta l4proto tcp tproxy to :$port meta mark set 0x1 accept 2>/dev/null
            nft add rule ip proxy_tproxy prerouting \
                iifname "$LAN_IFACE" ether saddr "$mac" \
                ip daddr != "{ $VPN_EXCLUDE }" \
                meta l4proto udp tproxy to :$port meta mark set 0x1 accept 2>/dev/null
        elif [ "$vpn_val" = "false" ]; then
            nft add rule ip proxy_tproxy prerouting \
                iifname "$LAN_IFACE" ether saddr "$mac" accept 2>/dev/null
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
    if [ -f "$STATE_FILE" ] && ! grep -q "\"profile_id\":\"$DEFAULT_PID\"[,\"}]" "$STATE_FILE"; then
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
        iifname "$LAN_IFACE" \
        ip daddr != "{ $VPN_EXCLUDE }" \
        meta l4proto tcp tproxy to :$DEFAULT_VPN_PORT meta mark set 0x1 accept 2>/dev/null
    nft add rule ip proxy_tproxy prerouting \
        iifname "$LAN_IFACE" \
        ip daddr != "{ $VPN_EXCLUDE }" \
        meta l4proto udp tproxy to :$DEFAULT_VPN_PORT meta mark set 0x1 accept 2>/dev/null
    logger -t proxy-routing "Catch-all VPN (port $DEFAULT_VPN_PORT, global_except_ru) enabled"

    # Catch-all: zapret OFF for unknown devices
    nft add rule inet proxy_route forward_zapret iifname "$LAN_IFACE" return 2>/dev/null
    logger -t proxy-routing "Catch-all zapret OFF (return) enabled"

    # Restore kill switch at the very end of the chain
    if [ "$(cat /etc/vpn_killswitch 2>/dev/null)" = "1" ]; then
        nft add rule ip proxy_tproxy prerouting \
            iifname "$LAN_IFACE" \
            ip daddr != "{ 10.0.0.0/8, 127.0.0.0/8, 192.168.0.0/16 }" \
            drop comment '"killswitch"' 2>/dev/null
        logger -t proxy-routing "Kill switch restored"
    fi
}
INITEOF
chmod +x /etc/init.d/proxy-routing

# ===== 16. Enable and start services =====
log "Enabling and starting services..."

/etc/init.d/proxy-routing enable
/etc/init.d/proxy-routing start || warn "proxy-routing failed to start"

/etc/init.d/sing-box enable
/etc/init.d/sing-box start || warn "sing-box failed to start, check configs"

# Zapret uses sysv init — enable via rc.d symlink, start directly
if [ "$SETUP_MODE" != "vpn-only" ]; then
    if [ -x /etc/init.d/zapret2 ]; then
        ln -sf /etc/init.d/zapret2 /etc/rc.d/S99zapret2 2>/dev/null
        ZAPRET_INIT=$(readlink -f /etc/init.d/zapret2 2>/dev/null || ls -l /etc/init.d/zapret2 | awk '{print $NF}')
        "$ZAPRET_INIT" start || warn "zapret failed to start"
    else
        warn "zapret init script not found, skipping"
    fi
fi

/etc/init.d/uhttpd restart

wifi reload

# Save setup mode for CGI panel awareness
echo "$SETUP_MODE" > /etc/vpn_setup_mode

log "Setup complete! (mode: $SETUP_MODE)"
log "Web panel: http://${ROUTER_IP}/cgi-bin/vpn"
log "Connect to Wi-Fi: $WIFI_SSID / $WIFI_SSID_5G"
