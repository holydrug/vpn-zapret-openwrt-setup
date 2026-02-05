<img width="972" height="1006" alt="{2B09AAC5-1E2D-48F0-99E2-45941BB9E93C}" src="https://github.com/user-attachments/assets/ee2bdf6b-b50e-43d2-a7c0-d0e2d5facd49" />

[English](README.md) | **Русский**

# Cudy WR3000 OpenWrt Setup

Автоматическая настройка Cudy WR3000 (MT7981) на OpenWrt 24.x с sing-box VPN, zapret (DPI bypass) и веб-панелью управления.

## Что настраивается

- **sing-box** — два экземпляра VLESS+Reality:
  - `full_vpn` (порт 12345) — весь трафик через VPN
  - `global_except_ru` (порт 12346) — всё кроме RU через VPN
- **zapret (nfqws2)** — обход DPI для YouTube, Discord и т.д. без VPN
- **Веб-панель** (`http://192.168.2.1/cgi-bin/vpn`) — управление VPN и zapret per-device по MAC
- **nftables tproxy** — маршрутизация трафика устройств через sing-box
- **VPN по умолчанию** — все новые устройства автоматически идут через VPN (Global -RU) через catch-all правило nftables

## Поведение по умолчанию

Все новые устройства, подключающиеся к Wi-Fi, **автоматически маршрутизируются через VPN** (пресет global_except_ru — весь трафик кроме российских IP/доменов идёт через VLESS-прокси). Это реализовано через catch-all правило nftables tproxy в конце цепочки.

| Тип устройства | Поведение |
|---|---|
| Новое/неизвестное | VPN ON через catch-all (Global -RU) |
| С явным `vpn:true` | VPN ON по своим настройкам |
| С явным `vpn:false` | Прямой интернет (обход catch-all) |

Чтобы исключить устройство из VPN, выключите его в веб-панели — будет создано явное bypass-правило.

## Предварительные шаги (ручные)

1. Прошить Cudy WR3000 OpenWrt (sysupgrade)
2. Настроить сеть:
   - WAN: `eth0`, DHCP (получает от основного роутера)
   - LAN: `br-lan` (`eth1`), static `192.168.2.1/24`
3. Убедиться в SSH-доступе: `ssh root@192.168.2.1`
4. Подключить USB-флешку (монтируется как `/mnt/usb`)
5. Проверить интернет: `ping 8.8.8.8`

## Установка

```sh
# На роутере
cd /tmp
# Скопировать репозиторий на роутер (scp, wget, etc.)
scp -r user@host:cudy-openwrt-setup /tmp/cudy-openwrt-setup

cd /tmp/cudy-openwrt-setup
sh setup.sh
```

Скрипт запросит:

| Параметр | Описание | По умолчанию |
|---|---|---|
| `VLESS_SERVER` | IP VLESS-сервера | — |
| `VLESS_PORT` | Порт | `42832` |
| `VLESS_UUID` | UUID | — |
| `REALITY_PUBLIC_KEY` | Публичный ключ Reality | — |
| `REALITY_SHORT_ID` | Short ID | — |
| `REALITY_SNI` | SNI | `www.icloud.com` |
| `WIFI_SSID` | Имя Wi-Fi 2.4GHz | — |
| `WIFI_PASSWORD` | Пароль Wi-Fi | — |
| `WIFI_SSID_5G` | Имя Wi-Fi 5GHz | `{SSID}_5G` |

Можно передать через переменные окружения:

```sh
VLESS_SERVER=1.2.3.4 VLESS_UUID=xxx REALITY_PUBLIC_KEY=yyy REALITY_SHORT_ID=zzz \
WIFI_SSID=MyWiFi WIFI_PASSWORD=secret sh setup.sh
```

## Структура

```
├── setup.sh                          # Основной скрипт
├── configs/
│   ├── sing-box/                     # Шаблоны конфигов sing-box
│   ├── zapret/                       # Конфиг и хостлист zapret
│   └── nftables/                     # Скрипт создания nft таблиц
├── scripts/
│   ├── init.d/sing-box               # init.d скрипт
│   └── cgi-bin/vpn                   # CGI веб-панель
```

## Веб-панель

Доступна по адресу `http://192.168.2.1/cgi-bin/vpn`.

Возможности:
- Включение/выключение VPN per-device
- Включение/выключение zapret (DPI bypass) per-device
- Выбор пресета маршрутизации (Full VPN / Global -RU)
- Добавление/удаление устройств по MAC
- Именование устройств
- Кнопка **DEFAULT** — устройство под catch-all VPN (нажать для отключения)
- Новые устройства, добавленные через панель, получают VPN ON (Global -RU) по умолчанию

## Как это работает

### Цепочка nftables tproxy

Цепочка `ip proxy_tproxy` prerouting устроена так:

```
1. Per-MAC tproxy правила (vpn:true)     → трафик через sing-box на указанный порт
2. Per-MAC accept bypass (vpn:false)      → обход catch-all, прямой интернет
3. Catch-all tproxy правило               → весь оставшийся трафик через sing-box (порт 12346)
```

При отключении VPN для устройства через веб-панель добавляется явное `accept` bypass-правило, чтобы catch-all не применялся к этому устройству.

### Файлы состояния

- `/etc/vpn_state.json` — настройки VPN/zapret/routing per-device
- `/etc/device_names.json` — пользовательские имена устройств

## После перезагрузки

Все настройки автоматически восстанавливаются через init.d скрипт `proxy-tproxy`, который:
- Создаёт nftables таблицы и цепочки
- Настраивает ip rule/route для tproxy
- Восстанавливает per-device правила из `/etc/vpn_state.json`
- Добавляет bypass-правила для устройств с `vpn:false`
- Добавляет catch-all VPN правило в конец цепочки

## Заметка про IPv6

Если основной роутер (ONT от провайдера) не раздаёт IPv6 (типичная ситуация в России), отключите IPv6 RA и DHCPv6 на LAN-интерфейсе, иначе устройства будут показывать "No Internet":

```sh
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ra='disabled'
uci set dhcp.@dnsmasq[0].filter_aaaa='1'
uci commit dhcp
/etc/init.d/dnsmasq restart
/etc/init.d/odhcpd restart
```
