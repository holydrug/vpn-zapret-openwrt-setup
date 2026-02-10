<img width="972" height="1006" alt="{2B09AAC5-1E2D-48F0-99E2-45941BB9E93C}" src="https://github.com/user-attachments/assets/ee2bdf6b-b50e-43d2-a7c0-d0e2d5facd49" />

[English](README.md) | **Русский**

# OpenWrt VPN Setup

Автоматическая настройка VPN + обхода DPI для OpenWrt-роутеров с sing-box, zapret и веб-панелью управления. Протестировано на Cudy WR3000 (MT7981), работает на любом OpenWrt-устройстве с поддержкой sing-box и nftables.

## Что настраивается

- **sing-box** — мульти-профильный VLESS-прокси (Reality и plain `security=none`):
  - `full_vpn` — весь трафик через VPN
  - `global_except_ru` — всё кроме RU через VPN
  - Каждый профиль получает отдельную пару sing-box инстансов на уникальных портах
- **zapret (nfqws2)** — обход DPI для YouTube, Discord и т.д. без VPN
- **Веб-панель** (`http://<IP_РОУТЕРА>/cgi-bin/vpn`) — управление VPN и zapret per-device по MAC
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

## Совместимость

| Требование | Подробности |
|---|---|
| Версия OpenWrt | 23.05+ (протестировано на 24.x) |
| sing-box | Доступен в opkg (`opkg install sing-box`) |
| nftables | Обязательно (по умолчанию в OpenWrt 22+) |
| RAM | Рекомендуется 256 МБ (каждый профиль ≈ 2 инстанса sing-box) |
| USB-накопитель | Опционально, нужен только для zapret |

Настройка не привязана к конкретному роутеру — работает на любом OpenWrt-устройстве при соблюдении требований выше. Cudy WR3000 используется как референсная платформа.

## Предварительные шаги

1. Прошить роутер OpenWrt (sysupgrade или factory-образ)
2. Настроить сеть:
   - WAN: DHCP (получает IP от основного роутера)
   - LAN: статический IP (например `192.168.2.1/24`)
3. Убедиться в SSH-доступе: `ssh root@<IP_РОУТЕРА>`
4. (Опционально) Подключить USB-флешку для zapret (монтируется как `/mnt/usb`)
5. Проверить интернет: `ping 8.8.8.8`

> **Пример (Cudy WR3000):** WAN = `eth0` (DHCP), LAN = `br-lan` (`eth1`, static `192.168.2.1/24`). Имена интерфейсов могут отличаться на других роутерах — проверьте через `ip link`.

## Установка

```sh
# На роутере
cd /tmp
# Скопировать репозиторий на роутер (scp, wget, etc.)
scp -r user@host:cudy-openwrt-setup /tmp/cudy-openwrt-setup

cd /tmp/cudy-openwrt-setup
sh setup.sh
```

Скрипт принимает `vless://` URI (рекомендуется) или отдельные параметры:

**Вариант 1 — vless:// URI (рекомендуется):**

```sh
sh setup.sh
# При запросе вставьте vless:// URI
# Поддерживаются как Reality, так и plain (security=none) URI
```

**Вариант 2 — переменные окружения:**

```sh
VLESS_SERVER=1.2.3.4 VLESS_UUID=xxx REALITY_PUBLIC_KEY=yyy REALITY_SHORT_ID=zzz \
WIFI_SSID=MyWiFi WIFI_PASSWORD=secret sh setup.sh
```

**Параметры:**

| Параметр | Описание | По умолчанию |
|---|---|---|
| `VLESS_SERVER` | IP VLESS-сервера | — |
| `VLESS_PORT` | Порт | `42832` |
| `VLESS_UUID` | UUID | — |
| `REALITY_PUBLIC_KEY` | Публичный ключ Reality (не нужен для `security=none`) | — |
| `REALITY_SHORT_ID` | Short ID (не нужен для `security=none`) | — |
| `REALITY_SNI` | SNI | `www.icloud.com` |
| `WIFI_SSID` | Имя Wi-Fi 2.4GHz | — |
| `WIFI_PASSWORD` | Пароль Wi-Fi | — |
| `WIFI_SSID_5G` | Имя Wi-Fi 5GHz | `{SSID}_5G` |

## Структура репозитория

```
├── setup.sh                              # Основной скрипт
├── configs/
│   ├── sing-box/
│   │   ├── templates/                    # Шаблоны конфигов sing-box (синтаксис %%PLACEHOLDER%%)
│   │   │   ├── config_full_vpn.tpl.json
│   │   │   └── config_global_except_ru.tpl.json
│   │   └── rules/                        # Локальные наборы правил (geoip-ru.srs, geosite-category-ru.srs)
│   ├── zapret/                           # Конфиг и хостлист zapret
│   └── nftables/                         # Скрипт создания nft таблиц
├── scripts/
│   ├── init.d/sing-box                   # init.d скрипт
│   ├── cgi-bin/vpn                       # CGI веб-панель
│   └── update-rulesets.sh                # Обновление наборов правил (geoip/geosite)
```

## Веб-панель

Доступна по адресу `http://<IP_РОУТЕРА>/cgi-bin/vpn`.

Возможности:
- Включение/выключение VPN per-device
- Включение/выключение zapret (DPI bypass) per-device
- Выбор пресета маршрутизации (Full VPN / Global -RU)
- **Управление профилями:**
  - Добавление новых профилей через `vless://` URI (Reality и plain)
  - Удаление профилей
  - Переименование профилей
  - Назначение профилей отдельным устройствам
  - Установка профиля по умолчанию для новых устройств
- Добавление/удаление устройств по MAC
- Именование устройств
- Кнопка **DEFAULT** — устройство под catch-all VPN (нажать для отключения)
- Новые устройства, добавленные через панель, получают VPN ON (Global -RU) по умолчанию

## Как это работает

### Цепочка nftables tproxy

Цепочка `ip proxy_tproxy` prerouting устроена так:

```
1. Per-MAC tproxy правила (vpn:true)     → трафик через sing-box на порт профиля
2. Per-MAC accept bypass (vpn:false)      → обход catch-all, прямой интернет
3. Catch-all tproxy правило               → весь оставшийся трафик через sing-box (профиль по умолчанию)
```

При отключении VPN для устройства через веб-панель добавляется явное `accept` bypass-правило, чтобы catch-all не применялся к этому устройству.

### Файлы состояния

- `/etc/vpn_state.json` — настройки VPN/zapret/routing per-device
- `/etc/device_names.json` — пользовательские имена устройств
- `/etc/vless_profiles.json` — профили VLESS (серверы, порты, учётные данные)

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
