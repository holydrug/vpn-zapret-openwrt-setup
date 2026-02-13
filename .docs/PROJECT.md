# vpn-zapret-openwrt-setup — Обзор проекта

## Что это
Автоматизированная настройка VPN + обход DPI (zapret) на роутерах OpenWrt с веб-панелью управления.

## Стек
- **sing-box** — VLESS-прокси (Reality и plain). Два режима на профиль: `full_vpn` (весь трафик) и `global_except_ru` (всё кроме RU)
- **zapret (nfqws2)** — обход DPI для YouTube, Discord и т.д. без VPN
- **nftables tproxy** — маршрутизация трафика на уровне устройств (по MAC-адресу)
- **CGI веб-панель** (ash shell) — управление VPN/zapret для каждого устройства
- **ash shell** — всё написано под BusyBox ash (не bash), совместимо с OpenWrt

## Архитектура маршрутизации

### Уровень 1: nftables (MAC → sing-box)
```
Пакет от устройства
  → таблица ip proxy_tproxy, chain prerouting
    → per-MAC правила: tproxy → sing-box порт (VPN ON) или accept (VPN OFF)
    → catch-all: неизвестные устройства → VPN по дефолту
```

### Уровень 2: sing-box (домены → VPN или direct)
```
sing-box получает пакет через tproxy
  → sniff определяет домен
  → route rules (первое совпадение):
    1. IP VPN-сервера → direct
    2. geoip-ru / geosite-category-ru → direct (только в global_except_ru)
    3. default → vless-out (VPN)
```

### Уровень 3: zapret (DPI bypass)
```
Таблица inet proxy_route, chain forward_zapret
  → per-MAC: accept (zapret ON) или return (zapret OFF)
```

## Ключевые файлы

### Скрипты
| Файл | Назначение |
|------|-----------|
| `setup.sh` | Основной скрипт установки. Ставит пакеты, генерит конфиги, настраивает Wi-Fi |
| `scripts/cgi-bin/vpn` | CGI веб-панель (~970 строк ash). UI + все действия (VPN on/off, zapret, профили) |
| `ssh_cmd.py` | Хелпер для SSH-команд на роутер с ПК |

### Шаблоны sing-box
| Файл | Назначение |
|------|-----------|
| `configs/sing-box/templates/config_full_vpn.tpl.json` | Шаблон: весь трафик через VPN |
| `configs/sing-box/templates/config_global_except_ru.tpl.json` | Шаблон: всё кроме RU через VPN |
| `configs/sing-box/rules/geoip-ru.srs` | Бинарный rule set: российские IP |
| `configs/sing-box/rules/geosite-category-ru.srs` | Бинарный rule set: российские домены |

### nftables
| Файл | Назначение |
|------|-----------|
| `configs/nftables/proxy-tproxy.sh` | Создание nft таблиц/цепочек для tproxy и zapret |

### Конфиги на роутере (генерируются)
| Файл | Назначение |
|------|-----------|
| `/etc/vless_profiles.json` | Профили VPN (до 4 штук), порты, серверы |
| `/etc/vpn_state.json` | Состояние устройств: VPN on/off, zapret, routing, profile_id |
| `/etc/device_names.json` | Кастомные имена устройств |
| `/etc/sing-box/config_{mode}_{pid}.json` | Сгенерированные конфиги sing-box |
| `/etc/vpn_lan_iface` | LAN интерфейс (br-lan по дефолту) |
| `/etc/vpn_setup_mode` | Режим установки (full/vpn-only/full-git) |
| `/etc/init.d/proxy-routing` | init.d скрипт: восстановление nft правил при перезагрузке |

## Генерация конфигов sing-box

Функция `generate_configs()` (есть и в setup.sh, и в CGI):
1. Берёт шаблон `.tpl.json`
2. `sed` заменяет плейсхолдеры: `%%LISTEN_PORT%%`, `%%VLESS_SERVER%%`, `%%VLESS_UUID%%` и т.д.
3. `awk` вставляет блок security (TLS/Reality) из temp-файла вместо `%%VLESS_SECURITY_BLOCK%%`
4. Результат → `/etc/sing-box/config_{mode}_{pid}.json`

## Веб-панель (CGI)

Секции UI:
1. **Profiles** — добавление/удаление VPN-профилей (vless:// URI), выбор дефолтного
2. **Add Device** — ручное добавление устройства по MAC
3. **Device List** — для каждого устройства: VPN toggle, Zapret toggle, Routing (Full VPN / Global -RU), Profile select

Все действия — POST/GET → обработка → 302 redirect → обновлённая страница.

## Варианты установки (setup.sh)

| Режим | Что ставится | Размер |
|-------|-------------|--------|
| `full` (default) | VPN + zapret (tarball) | ~18 MB |
| `vpn-only` | Только VPN, без zapret | ~15 MB |
| `full-git` | VPN + zapret (git clone) | ~48 MB |
