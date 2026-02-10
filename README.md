<img width="972" height="1006" alt="{2B09AAC5-1E2D-48F0-99E2-45941BB9E93C}" src="https://github.com/user-attachments/assets/ee2bdf6b-b50e-43d2-a7c0-d0e2d5facd49" />

**English** | [Русский](README_RU.md)

# OpenWrt VPN Setup

Automated VPN + DPI bypass setup for OpenWrt routers with sing-box, zapret, and a web control panel. Tested on Cudy WR3000 (MT7981), works on any OpenWrt device with sing-box and nftables support.

## What Gets Configured

- **sing-box** — multi-profile VLESS proxy (Reality and plain `security=none`):
  - `full_vpn` — all traffic through VPN
  - `global_except_ru` — all traffic through VPN except Russian IPs/domains
  - Each profile gets a dedicated pair of sing-box instances on unique ports
- **zapret (nfqws2)** — DPI bypass for YouTube, Discord, etc. without VPN
- **Web panel** (`http://<ROUTER_IP>/cgi-bin/vpn`) — per-device VPN and zapret control by MAC address
- **nftables tproxy** — per-device traffic routing through sing-box
- **Default VPN** — all new/unknown devices automatically routed through VPN (Global -RU) via catch-all nftables rule

## Default Behavior

All new devices connecting to Wi-Fi are **automatically routed through VPN** (global_except_ru preset — all traffic except Russian IPs/domains goes through VLESS proxy). This is achieved via a catch-all nftables tproxy rule at the end of the chain.

| Device type | Behavior |
|---|---|
| New/unknown device | VPN ON via catch-all (Global -RU) |
| Device with explicit `vpn:true` | VPN ON per its own settings |
| Device with explicit `vpn:false` | Direct internet (bypass catch-all) |

To exclude a device from VPN, toggle it off in the web panel — an explicit bypass rule will be created.

## Compatibility

| Requirement | Details |
|---|---|
| OpenWrt version | 23.05+ (tested on 24.x) |
| sing-box | Available in opkg (`opkg install sing-box`) |
| nftables | Required (default in OpenWrt 22+) |
| RAM | 256 MB recommended (each profile ≈ 2 sing-box instances) |
| USB storage | Optional, needed only for zapret |

The setup is router-agnostic — it works on any OpenWrt device as long as the requirements above are met. Cudy WR3000 is used as the reference platform.

## Prerequisites

1. Flash your router with OpenWrt (sysupgrade or factory image)
2. Configure networking:
   - WAN: DHCP (receives IP from upstream router)
   - LAN: static IP (e.g. `192.168.2.1/24`)
3. Ensure SSH access: `ssh root@<ROUTER_IP>`
4. (Optional) Attach USB drive for zapret (mounted at `/mnt/usb`)
5. Verify internet connectivity: `ping 8.8.8.8`

> **Example (Cudy WR3000):** WAN = `eth0` (DHCP), LAN = `br-lan` (`eth1`, static `192.168.2.1/24`). Interface names may differ on other routers — check with `ip link`.

## Installation

```sh
# On the router
cd /tmp
# Copy the repo to the router (scp, wget, etc.)
scp -r user@host:cudy-openwrt-setup /tmp/cudy-openwrt-setup

cd /tmp/cudy-openwrt-setup
sh setup.sh
```

The script accepts a `vless://` URI as input (recommended) or individual parameters:

**Option 1 — vless:// URI (recommended):**

```sh
sh setup.sh
# When prompted, paste your vless:// URI
# Both Reality and plain (security=none) URIs are supported
```

**Option 2 — environment variables:**

```sh
VLESS_SERVER=1.2.3.4 VLESS_UUID=xxx REALITY_PUBLIC_KEY=yyy REALITY_SHORT_ID=zzz \
WIFI_SSID=MyWiFi WIFI_PASSWORD=secret sh setup.sh
```

**Parameters:**

| Parameter | Description | Default |
|---|---|---|
| `VLESS_SERVER` | VLESS server IP | — |
| `VLESS_PORT` | Port | `42832` |
| `VLESS_UUID` | UUID | — |
| `REALITY_PUBLIC_KEY` | Reality public key (not needed for `security=none`) | — |
| `REALITY_SHORT_ID` | Short ID (not needed for `security=none`) | — |
| `REALITY_SNI` | SNI | `www.icloud.com` |
| `WIFI_SSID` | Wi-Fi 2.4GHz SSID | — |
| `WIFI_PASSWORD` | Wi-Fi password | — |
| `WIFI_SSID_5G` | Wi-Fi 5GHz SSID | `{SSID}_5G` |

## Repository Structure

```
├── setup.sh                              # Main setup script
├── configs/
│   ├── sing-box/
│   │   ├── templates/                    # sing-box config templates (%%PLACEHOLDER%% syntax)
│   │   │   ├── config_full_vpn.tpl.json
│   │   │   └── config_global_except_ru.tpl.json
│   │   └── rules/                        # Local rule sets (geoip-ru.srs, geosite-category-ru.srs)
│   ├── zapret/                           # zapret config and hostlist
│   └── nftables/                         # nft table creation script
├── scripts/
│   ├── init.d/sing-box                   # sing-box init.d script
│   ├── cgi-bin/vpn                       # CGI web panel
│   └── update-rulesets.sh                # Rule set updater (geoip/geosite)
```

## Web Panel

Available at `http://<ROUTER_IP>/cgi-bin/vpn`.

Features:
- Toggle VPN on/off per device
- Toggle zapret (DPI bypass) on/off per device
- Select routing preset (Full VPN / Global except RU)
- **Multi-profile management:**
  - Add new profiles via `vless://` URI (Reality and plain)
  - Delete profiles
  - Rename profiles
  - Assign profiles to individual devices
  - Set default profile for new devices
- Add/remove devices by MAC address
- Custom device naming
- **DEFAULT** button — indicates device is covered by catch-all VPN (click to disable)
- New devices added via the panel default to VPN ON (Global -RU)

## How It Works

### nftables tproxy chain

The `ip proxy_tproxy` prerouting chain is structured as follows:

```
1. Per-MAC tproxy rules (vpn:true)    → route through sing-box at profile-specific port
2. Per-MAC accept bypass (vpn:false)  → skip catch-all, direct internet
3. Catch-all tproxy rule              → route all remaining traffic through sing-box (default profile)
```

When VPN is turned OFF for a device via the web panel, an explicit `accept` bypass rule is inserted so the catch-all doesn't apply to that device.

### State files

- `/etc/vpn_state.json` — per-device VPN/zapret/routing settings
- `/etc/device_names.json` — custom device names
- `/etc/vless_profiles.json` — VLESS profiles (servers, ports, credentials)

## After Reboot

All settings are automatically restored via the `proxy-tproxy` init.d script, which:
- Creates nftables tables and chains
- Sets up ip rule/route for tproxy
- Restores per-device rules from `/etc/vpn_state.json`
- Adds bypass rules for devices with `vpn:false`
- Appends catch-all VPN rule at the end

## IPv6 Note

If your upstream router does not provide IPv6 (common with ISP-provided ONTs in Russia), disable IPv6 RA and DHCPv6 on the LAN interface to prevent "No Internet" indicators on client devices:

```sh
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ra='disabled'
uci set dhcp.@dnsmasq[0].filter_aaaa='1'
uci commit dhcp
/etc/init.d/dnsmasq restart
/etc/init.d/odhcpd restart
```
