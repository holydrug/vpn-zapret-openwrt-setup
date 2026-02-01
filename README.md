<img width="972" height="1006" alt="{2B09AAC5-1E2D-48F0-99E2-45941BB9E93C}" src="https://github.com/user-attachments/assets/ee2bdf6b-b50e-43d2-a7c0-d0e2d5facd49" />


# Cudy WR3000 OpenWrt Setup

Автоматическая настройка Cudy WR3000 (MT7981) на OpenWrt 24.x с sing-box VPN, zapret (DPI bypass) и веб-панелью управления.

## Что настраивается

- **sing-box** — два VLESS+Reality экземпляра:
  - `full_vpn` (порт 12345) — весь трафик через VPN
  - `global_except_ru` (порт 12346) — всё кроме RU через VPN
- **zapret (nfqws2)** — обход DPI для YouTube, Discord и т.д. без VPN
- **Веб-панель** (`http://192.168.2.1/cgi-bin/vpn`) — управление VPN и zapret per-device по MAC
- **nftables tproxy** — маршрутизация трафика устройств через sing-box

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
|----------|----------|-------------|
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
│   ├── init.d/sing-box               # init.d для sing-box
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

## После перезагрузки

Все настройки автоматически восстанавливаются через init.d скрипт `proxy-tproxy`, который:
- Создаёт nftables таблицы
- Настраивает ip rule/route для tproxy
- Восстанавливает per-device правила из `/etc/vpn_state.json`
