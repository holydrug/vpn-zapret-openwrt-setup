#!/bin/sh
# Upgrade script for vpn-zapret-openwrt-setup
# Safe incremental updates: templates, scripts, adblock, AdGuard Home
# Usage: sh upgrade.sh [--all|--adblock-only|--agh-only|--templates-only|--rollback]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ===== Colors & helpers =====
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { printf "${GREEN}[+]${NC} %s\n" "$1"; }
warn() { printf "${RED}[!]${NC} %s\n" "$1"; }
ask() { printf "${CYAN}[?]${NC} %s" "$1"; }

deploy() { cp "$1" "$2" && sed -i 's/\r$//' "$2"; }

# ===== State detection =====
detect_state() {
    HAS_PROFILES="0"
    [ -f /etc/vless_profiles.json ] && grep -q '"profiles":\[' /etc/vless_profiles.json && HAS_PROFILES="1"

    HAS_ADBLOCK="0"
    [ -f /etc/sing-box/rules/geosite-category-ads-all.srs ] && HAS_ADBLOCK="1"

    ADBLOCK_ENABLED="0"
    [ -f /etc/vpn_adblock ] && [ "$(cat /etc/vpn_adblock 2>/dev/null)" = "1" ] && ADBLOCK_ENABLED="1"

    HAS_AGH="0"
    [ -f /etc/vpn_agh_installed ] && [ "$(cat /etc/vpn_agh_installed 2>/dev/null)" = "1" ] && HAS_AGH="1"
    command -v AdGuardHome >/dev/null 2>&1 && HAS_AGH="1"

    DNSMASQ_PORT=$(uci get dhcp.@dnsmasq[0].port 2>/dev/null || echo "53")

    SCHEMA_VERSION="0"
    [ -f /etc/vpn_upgrade_version ] && SCHEMA_VERSION=$(cat /etc/vpn_upgrade_version 2>/dev/null) || true
}

# ===== Parse flags =====
MODE=""
case "${1:-}" in
    --all)            MODE="all" ;;
    --adblock-only)   MODE="adblock" ;;
    --agh-only)       MODE="agh" ;;
    --templates-only) MODE="templates" ;;
    --rollback)       MODE="rollback" ;;
    "") ;;
    *)
        echo "Usage: $0 [--all|--adblock-only|--agh-only|--templates-only|--rollback]"
        exit 1
        ;;
esac

detect_state

if [ "$HAS_PROFILES" = "0" ]; then
    warn "No existing installation found. Run setup.sh first."
    exit 1
fi

# ===== Interactive menu =====
show_menu() {
    echo ""
    echo "=== Upgrade Menu ==="
    echo "  1) Update templates & scripts only"
    echo "  2) Enable sing-box adblock (download rule-set + update templates)"
    echo "  3) Install AdGuard Home (DNS-level ad blocking)"
    echo "  4) Full upgrade (templates + adblock + AdGuard Home)"
    echo "  5) Rollback DNS (restore dnsmasq to :53, stop AGH)"
    echo "  6) Abort"
    echo ""

    # Show current state
    echo "Current state:"
    [ "$HAS_ADBLOCK" = "1" ] && echo "  Adblock rule-set: installed" || echo "  Adblock rule-set: not installed"
    [ "$ADBLOCK_ENABLED" = "1" ] && echo "  Adblock: ON" || echo "  Adblock: OFF"
    [ "$HAS_AGH" = "1" ] && echo "  AdGuard Home: installed (dnsmasq port: $DNSMASQ_PORT)" || echo "  AdGuard Home: not installed"
    echo ""

    ask "Select action [6]: "; read MENU_CHOICE
    case "$MENU_CHOICE" in
        1) MODE="templates" ;;
        2) MODE="adblock" ;;
        3) MODE="agh" ;;
        4) MODE="all" ;;
        5) MODE="rollback" ;;
        *) exit 0 ;;
    esac
}

[ -z "$MODE" ] && show_menu

# ===== Backup =====
backup_state() {
    log "Backing up current state..."
    local bak="/tmp/vpn-upgrade-backup-$$"
    mkdir -p "$bak"
    cp -f /etc/sing-box/templates/*.tpl.json "$bak/" 2>/dev/null || true
    cp -f /etc/sing-box/config_*.json "$bak/" 2>/dev/null || true
    [ -f /etc/config/dhcp ] && cp -f /etc/config/dhcp "$bak/dhcp.uci" 2>/dev/null || true
    BACKUP_DIR="$bak"
    log "Backup saved to $BACKUP_DIR"
}

# ===== Upgrade templates =====
upgrade_templates() {
    log "Upgrading sing-box templates..."
    mkdir -p /etc/sing-box/templates
    deploy "$SCRIPT_DIR/configs/sing-box/templates/config_full_vpn.tpl.json" \
           /etc/sing-box/templates/config_full_vpn.tpl.json
    deploy "$SCRIPT_DIR/configs/sing-box/templates/config_global_except_ru.tpl.json" \
           /etc/sing-box/templates/config_global_except_ru.tpl.json
    log "Templates updated (v2 with adblock placeholders)"
}

# ===== Upgrade scripts =====
upgrade_scripts() {
    log "Upgrading scripts..."

    # Shared library
    mkdir -p /etc/sing-box/lib
    deploy "$SCRIPT_DIR/scripts/lib/generate.sh" /etc/sing-box/lib/generate.sh

    # Init scripts
    deploy "$SCRIPT_DIR/scripts/init.d/proxy-routing" /etc/init.d/proxy-routing
    chmod +x /etc/init.d/proxy-routing

    deploy "$SCRIPT_DIR/scripts/init.d/sing-box" /etc/init.d/sing-box
    chmod +x /etc/init.d/sing-box

    # CGI panel
    mkdir -p /www/cgi-bin
    deploy "$SCRIPT_DIR/scripts/cgi-bin/vpn" /www/cgi-bin/vpn
    chmod +x /www/cgi-bin/vpn

    # Update rulesets script
    deploy "$SCRIPT_DIR/scripts/update-rulesets.sh" /etc/sing-box/update-rulesets.sh
    chmod +x /etc/sing-box/update-rulesets.sh

    # Nftables
    deploy "$SCRIPT_DIR/configs/nftables/proxy-tproxy.sh" /etc/proxy-tproxy.sh
    chmod +x /etc/proxy-tproxy.sh

    log "Scripts upgraded"
}

# ===== Install adblock ruleset =====
install_adblock_ruleset() {
    log "Downloading adblock rule-set..."
    local url="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs"
    local dest="/etc/sing-box/rules/geosite-category-ads-all.srs"
    local tmp="${dest}.tmp"

    mkdir -p /etc/sing-box/rules

    curl -sL --connect-timeout 15 --max-time 60 -o "$tmp" "$url" 2>/dev/null
    if [ $? -ne 0 ]; then
        warn "Failed to download adblock rule-set"
        rm -f "$tmp"
        return 1
    fi

    local size=$(wc -c < "$tmp" | tr -d ' ')
    if [ "$size" -lt 500 ]; then
        warn "Adblock rule-set too small (${size} bytes), download may have failed"
        rm -f "$tmp"
        return 1
    fi

    mv "$tmp" "$dest"
    log "Adblock rule-set downloaded (${size} bytes)"

    # Enable adblock
    echo "1" > /etc/vpn_adblock
    log "Adblock enabled"
    return 0
}

# ===== Regenerate configs =====
regenerate_configs() {
    log "Regenerating sing-box configs from templates..."
    PROFILES_FILE="/etc/vless_profiles.json"
    TEMPLATES_DIR="/etc/sing-box/templates"
    CUSTOM_RULES_FILE="/etc/sing-box/custom_rules.json"
    [ -f "$CUSTOM_RULES_FILE" ] || echo '{"direct":[],"vpn":[]}' > "$CUSTOM_RULES_FILE"

    . "$SCRIPT_DIR/scripts/lib/generate.sh"
    regenerate_all_configs
    log "Configs regenerated and sing-box restarted"
}

# ===== Install AdGuard Home =====
install_agh() {
    if [ "$HAS_AGH" = "1" ]; then
        log "AdGuard Home already installed"
        return 0
    fi

    log "Installing AdGuard Home..."

    # Try opkg first
    if opkg list 2>/dev/null | grep -q adguardhome; then
        log "Installing via opkg..."
        opkg update 2>/dev/null
        opkg install adguardhome && {
            log "AdGuard Home installed via opkg"
            deploy_agh_config
            return 0
        }
    fi

    # Fallback: direct binary download
    log "Downloading AdGuard Home binary..."
    local arch
    arch=$(uname -m)
    case "$arch" in
        aarch64) arch="linux-arm64" ;;
        armv7l)  arch="linux-armv7" ;;
        mips*)   arch="linux-mipsle-softfloat" ;;
        x86_64)  arch="linux-amd64" ;;
        *)
            warn "Unsupported architecture: $arch"
            return 1
            ;;
    esac

    local agh_url="https://static.adtidy.org/adguardhome/release/AdGuardHome_${arch}.tar.gz"
    local tmp_dir="/tmp/agh_install_$$"
    mkdir -p "$tmp_dir"

    curl -sL --connect-timeout 30 --max-time 120 -o "$tmp_dir/agh.tar.gz" "$agh_url" 2>/dev/null
    if [ $? -ne 0 ]; then
        warn "Failed to download AdGuard Home"
        rm -rf "$tmp_dir"
        return 1
    fi

    tar xzf "$tmp_dir/agh.tar.gz" -C "$tmp_dir" 2>/dev/null
    if [ ! -f "$tmp_dir/AdGuardHome/AdGuardHome" ]; then
        warn "Failed to extract AdGuard Home"
        rm -rf "$tmp_dir"
        return 1
    fi

    mkdir -p /opt/AdGuardHome
    cp "$tmp_dir/AdGuardHome/AdGuardHome" /opt/AdGuardHome/
    chmod +x /opt/AdGuardHome/AdGuardHome
    ln -sf /opt/AdGuardHome/AdGuardHome /usr/bin/AdGuardHome
    rm -rf "$tmp_dir"

    # Create init.d script for AGH
    cat > /etc/init.d/adguardhome <<'AGHEOF'
#!/bin/sh /etc/rc.common

START=95
STOP=15

USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /opt/AdGuardHome/AdGuardHome -c /etc/AdGuardHome.yaml -w /opt/AdGuardHome --no-check-update
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
AGHEOF
    chmod +x /etc/init.d/adguardhome

    deploy_agh_config
    log "AdGuard Home installed"
}

deploy_agh_config() {
    # opkg package uses /etc/adguardhome.yaml (lowercase)
    local agh_conf="/etc/adguardhome.yaml"
    if [ ! -f "$agh_conf" ]; then
        log "Deploying AdGuard Home config..."
        deploy "$SCRIPT_DIR/configs/adguardhome/AdGuardHome.yaml" "$agh_conf"
    else
        log "AdGuard Home config exists, keeping current"
    fi
}

# ===== DNS migration =====
migrate_dns() {
    log "Starting DNS migration (dnsmasq -> AGH)..."

    # Step 1: verify DNS works before touching anything
    if ! check_dns "pre-migration"; then
        warn "DNS not working before migration, aborting"
        return 1
    fi

    # Step 2: enable AGH (don't start yet — dnsmasq still holds :53)
    /etc/init.d/adguardhome enable

    # Step 3: atomic swap — stop dnsmasq, start AGH, restart dnsmasq on :5353
    # This minimizes the window where nothing listens on :53
    log "Swapping DNS: dnsmasq :53 -> AGH :53 + dnsmasq :5353..."
    /etc/init.d/dnsmasq stop
    /etc/init.d/adguardhome start

    # Poll for AGH to bind :53 (up to 5s)
    local tries=0
    while [ "$tries" -lt 5 ]; do
        if netstat -tlnp 2>/dev/null | grep 'AdGuard' | grep -q ':53 ' || \
           netstat -ulnp 2>/dev/null | grep 'AdGuard' | grep -q ':53 '; then
            break
        fi
        sleep 1
        tries=$((tries + 1))
    done

    # Now move dnsmasq to :5353 and restart (AGH upstreams to it)
    uci set dhcp.@dnsmasq[0].port=5353
    uci commit dhcp
    /etc/init.d/dnsmasq start

    # Step 4: verify DNS end-to-end
    sleep 1
    if check_dns "post-migration"; then
        log "DNS migration successful!"
        echo "1" > /etc/vpn_agh_installed
        return 0
    else
        warn "DNS check failed after migration, rolling back..."
        rollback_dns
        return 1
    fi
}

# ===== DNS check =====
check_dns() {
    local label="${1:-check}"
    # Try nslookup with timeout
    if command -v nslookup >/dev/null 2>&1; then
        nslookup google.com 127.0.0.1 >/dev/null 2>&1 && return 0
    fi
    # Fallback: try curl
    if command -v curl >/dev/null 2>&1; then
        curl -s --connect-timeout 3 --max-time 5 http://google.com >/dev/null 2>&1 && return 0
    fi
    warn "DNS check failed ($label)"
    return 1
}

# ===== Rollback DNS =====
rollback_dns() {
    log "Rolling back DNS to dnsmasq on :53..."

    # Stop AdGuard Home
    /etc/init.d/adguardhome stop 2>/dev/null || true
    /etc/init.d/adguardhome disable 2>/dev/null || true
    killall AdGuardHome 2>/dev/null || true

    # Restore dnsmasq to port 53
    uci set dhcp.@dnsmasq[0].port=53
    uci commit dhcp
    /etc/init.d/dnsmasq restart

    # Wait briefly and verify
    sleep 1
    if check_dns "rollback"; then
        log "DNS restored to dnsmasq on :53"
    else
        warn "DNS may still be down after rollback — check manually"
    fi

    echo "0" > /etc/vpn_agh_installed
}

# ===== Main orchestration =====
case "$MODE" in
    templates)
        backup_state
        upgrade_templates
        upgrade_scripts
        [ -f /etc/vpn_adblock ] || echo "0" > /etc/vpn_adblock
        regenerate_configs
        log "Templates & scripts upgrade complete"
        ;;
    adblock)
        backup_state
        upgrade_templates
        upgrade_scripts
        install_adblock_ruleset
        regenerate_configs
        log "Adblock upgrade complete"
        ;;
    agh)
        backup_state
        upgrade_scripts
        install_agh
        migrate_dns
        log "AdGuard Home installation complete"
        log "Web UI: http://$(uci get network.lan.ipaddr 2>/dev/null || echo '192.168.1.1'):3000"
        ;;
    all)
        backup_state
        upgrade_templates
        upgrade_scripts
        install_adblock_ruleset
        regenerate_configs
        install_agh
        migrate_dns
        log "Full upgrade complete!"
        log "AGH Web UI: http://$(uci get network.lan.ipaddr 2>/dev/null || echo '192.168.1.1'):3000"
        log "VPN Panel: http://$(uci get network.lan.ipaddr 2>/dev/null || echo '192.168.1.1')/cgi-bin/vpn"
        ;;
    rollback)
        rollback_dns
        log "Rollback complete"
        ;;
esac

# Update schema version (skip on rollback)
[ "$MODE" != "rollback" ] && echo "2" > /etc/vpn_upgrade_version || true
