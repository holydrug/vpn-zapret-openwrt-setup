# Plan: Кастомные правила маршрутизации доменов (bypass / force-VPN)

## Контекст

Нужно добавлять кастомные правила для доменов через веб-панель:
- **Direct (мимо VPN)**: домен идёт напрямую (пример: `crpt.tech` — рабочие ресурсы)
- **VPN (принудительно через VPN)**: домен идёт через VPN (полезно в режиме Global -RU чтобы пустить русский домен через VPN)

Правила **глобальные** — применяются ко всем устройствам.

## Как работает

### Поток трафика (пример: crpt.tech → direct)

```
Устройство → запрос к images.crpt.tech
    ↓
nftables: VPN включён → tproxy → sing-box
    ↓
sing-box (sniff определяет домен "images.crpt.tech")
    ↓
Route rules (первое совпадение):
  1. IP VPN-сервера → direct                    (не совпало)
  2. domain_suffix: ["crpt.tech"] → direct      ← КАСТОМНОЕ ПРАВИЛО
  3. geoip-ru / geosite-ru → direct             (не дошли)
  4. default → vless-out (VPN)                   (не дошли)
    ↓
Результат: crpt.tech идёт НАПРЯМУЮ, минуя VPN
```

DNS тоже учитывается: bypass-домены резолвятся через локальный DNS (`dns-direct`), а не через VPN.

## Хранение

**Файл**: `/etc/sing-box/custom_rules.json`
```json
{"direct":["crpt.tech","work.example.com"],"vpn":["some-blocked-site.ru"]}
```

## Файлы для изменения

### 1. `configs/sing-box/templates/config_global_except_ru.tpl.json`
Добавить плейсхолдеры `%%CUSTOM_ROUTE_RULES%%` и `%%CUSTOM_DNS_RULES%%`.

**DNS** — между двумя существующими правилами:
```json
"rules": [
  { "outbound": "direct", "server": "dns-direct" },
%%CUSTOM_DNS_RULES%%
  { "rule_set": "geosite-category-ru", "server": "dns-direct" }
]
```

**Route** — между ip_cidr и rule_set:
```json
"rules": [
  { "ip_cidr": ["%%VLESS_SERVER%%/32"], "outbound": "direct" },
%%CUSTOM_ROUTE_RULES%%
  { "rule_set": ["geoip-ru", "geosite-category-ru"], "outbound": "direct" }
]
```

Запятые: ip_cidr уже имеет `,` после `}`. Контент плейсхолдера — правила с trailing `,`. Если пусто — awk удаляет строку, JSON валиден.

### 2. `configs/sing-box/templates/config_full_vpn.tpl.json`
Те же плейсхолдеры, но контент с LEADING `,` (нет правил после плейсхолдера).

### 3. `scripts/cgi-bin/vpn` (CGI панель)

**Новые функции:**
- `add_custom_rule(domain, direction)` — добавить домен в direct/vpn массив
- `delete_custom_rule(domain, direction)` — удалить домен
- `build_custom_rules_file(mode, route_file, dns_file)` — собрать JSON-сниппеты для подстановки
- `regenerate_all_configs()` — пересобрать конфиги всех профилей + рестарт sing-box

**Новые actions:**
- `add_rule` (POST): `domain` + `rule_action` (direct/vpn) → добавить правило → regenerate
- `delete_rule` (GET): `domain` + `rule_action` → удалить правило → regenerate

**Модификация `generate_configs()`:**
Расширить awk pipeline — добавить подстановку `%%CUSTOM_ROUTE_RULES%%` и `%%CUSTOM_DNS_RULES%%` из temp-файлов (тот же паттерн что `%%VLESS_SECURITY_BLOCK%%`).

**Новая UI-секция "Custom Routes"** (между Profiles и Add Device):
```
┌──────────────────────────────────────────────┐
│ Custom Routes                                │
│                                              │
│  crpt.tech              DIRECT    [delete]   │
│  blocked-site.ru        VPN       [delete]   │
│                                              │
│  [domain input] [Direct ▼] [Add Rule]       │
│                                              │
│  * покрывает домен и все поддомены           │
└──────────────────────────────────────────────┘
```

### 4. `setup.sh`
Те же изменения в `generate_configs()` + функция `build_custom_rules_file()`.
Инициализация файла: `[ -f custom_rules.json ] || echo '{"direct":[],"vpn":[]}' > custom_rules.json`

## build_custom_rules_file() — логика

```sh
build_custom_rules_file() {
    local mode="$1" route_out="$2" dns_out="$3"
    local rules_file="/etc/sing-box/custom_rules.json"
    > "$route_out"; > "$dns_out"
    [ -f "$rules_file" ] || return 0

    local direct_domains=$(grep -o '"direct":\[[^]]*\]' "$rules_file" | sed 's/"direct":\[//;s/\]$//' | tr -d ' ')
    local vpn_domains=$(grep -o '"vpn":\[[^]]*\]' "$rules_file" | sed 's/"vpn":\[//;s/\]$//' | tr -d ' ')

    case "$mode" in
        global_except_ru)
            # Trailing comma (есть правила после плейсхолдера)
            [ -n "$direct_domains" ] && {
                echo "      {\"domain_suffix\":[$direct_domains],\"outbound\":\"direct\"}," >> "$route_out"
                echo "      {\"domain_suffix\":[$direct_domains],\"server\":\"dns-direct\"}," >> "$dns_out"
            }
            [ -n "$vpn_domains" ] && {
                echo "      {\"domain_suffix\":[$vpn_domains],\"outbound\":\"vless-out\"}," >> "$route_out"
                echo "      {\"domain_suffix\":[$vpn_domains],\"server\":\"dns-remote\"}," >> "$dns_out"
            }
            ;;
        full_vpn)
            # Leading comma (плейсхолдер после последнего правила)
            [ -n "$direct_domains" ] && {
                echo "      ,{\"domain_suffix\":[$direct_domains],\"outbound\":\"direct\"}" >> "$route_out"
                echo "      ,{\"domain_suffix\":[$direct_domains],\"server\":\"dns-direct\"}" >> "$dns_out"
            }
            # force-vpn не нужен в full_vpn (и так всё через VPN)
            ;;
    esac
}
```

## Проверка

1. Добавить "direct" правило для `crpt.tech` через веб-панель
2. Проверить `/etc/sing-box/custom_rules.json` → `{"direct":["crpt.tech"],"vpn":[]}`
3. Проверить конфиг `config_global_except_ru_p1.json` → есть `domain_suffix` правило для crpt.tech
4. Проверить DNS-правила → crpt.tech → `dns-direct`
5. На роутере: `curl -I https://crpt.tech` идёт напрямую
6. Удалить правило → конфиги перегенерены без кастомного правила
7. Тест VPN-направления: добавить русский домен → идёт через VPN в режиме Global -RU
