#!/usr/bin/env bash
#
# fix-xray-karing — правит серверный Xray (Reality) из AmneziaVPN,
# чтобы к нему подключался Karing и другие клиенты на sing-box.
#
# Что делает:
#   1. находит конфиг Xray в контейнере AmneziaVPN;
#   2. делает резервную копию;
#   3. убирает flow xtls-rprx-vision у клиентов;
#   4. ставит realitySettings.minClientVer = "1.0.0" (и убирает maxClientVer);
#   5. перезапускает контейнер Xray;
#   6. показывает, что получилось.
#
# Запуск:
#   bash <(curl -fsSL https://raw.githubusercontent.com/griggsdevel/fix-xray-karing/main/fix.sh)
#
# Откат:
#   bash fix.sh --restore
#
# Никаких адресов, ключей и идентификаторов внутри нет — всё берётся с сервера.

set -uo pipefail

BACKUP_GLOB="config.json.bak.*"
FOUND_CFG=""

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m  x\033[0m %s\n' "$*" >&2; }

if [ "$(id -u)" -ne 0 ]; then
    err "запусти от root (sudo -i)"
    exit 1
fi

# ---------- поиск конфига ----------
find_config() {
    local p
    for p in \
        /opt/amnezia/xray/config.json \
        /opt/amnezia/xray/config/config.json \
        /opt/amnezia/xray/xray/config.json \
        /etc/xray/config.json \
        /usr/local/etc/xray/config.json
    do
        if [ -f "$p" ]; then
            FOUND_CFG="$p"
            return 0
        fi
    done

    # поиск по системе, если стандартные пути не подошли
    p=$(find /opt /etc /usr/local -maxdepth 5 -type f -name config.json 2>/dev/null \
        | while read -r f; do
              grep -q '"realitySettings"' "$f" 2>/dev/null && echo "$f" && break
          done)
    if [ -n "$p" ]; then
        FOUND_CFG="$p"
        return 0
    fi
    return 1
}

# ---------- откат ----------
if [ "${1:-}" = "--restore" ]; then
    if ! find_config; then
        err "конфиг Xray не найден"
        exit 1
    fi
    last=$(ls -1t "$FOUND_CFG".bak.* 2>/dev/null | head -1)
    [ -n "$last" ] || { err "резервных копий нет"; exit 1; }
    cp "$last" "$FOUND_CFG"
    ok "восстановлен из $(basename "$last")"
    if command -v docker >/dev/null 2>&1; then
        name=$(docker ps --format '{{.Names}}' | grep -i xray | head -1)
        [ -n "$name" ] && docker restart "$name" >/dev/null && ok "контейнер $name перезапущен"
    fi
    exit 0
fi

say "проверяю окружение"
command -v docker >/dev/null 2>&1 || warn "docker не найден — перезапуск сделаю через systemctl, если получится"

if ! command -v python3 >/dev/null 2>&1; then
    say "ставлю python3"
    (apt-get update -qq && apt-get install -y -qq python3) >/dev/null 2>&1 || {
        err "не удалось поставить python3"
        exit 1
    }
fi

say "ищу конфиг Xray"
if ! find_config; then
    err "конфиг Xray не найден"
    echo
    echo "Что есть в /opt/amnezia:"
    ls -la /opt/amnezia 2>/dev/null || echo "  каталога нет"
    echo
    echo "Контейнеры:"
    docker ps --format '  {{.Names}} ({{.Image}})' 2>/dev/null || echo "  docker недоступен"
    exit 1
fi
ok "конфиг: $FOUND_CFG"

backup="$FOUND_CFG.bak.$(date +%Y%m%d-%H%M%S)"
cp "$FOUND_CFG" "$backup"
ok "бэкап: $backup"

say "правлю конфиг"
python3 - "$FOUND_CFG" <<'PY'
import json
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    data = json.load(f)

changes = []
clients_total = 0

for inbound in data.get("inbounds", []):
    stream = inbound.get("streamSettings") or {}
    reality = stream.get("realitySettings")
    if reality is not None:
        if reality.get("minClientVer") != "1.0.0":
            reality["minClientVer"] = "1.0.0"
            changes.append("reality: minClientVer = 1.0.0")
        if "maxClientVer" in reality:
            reality.pop("maxClientVer", None)
            changes.append("reality: убран maxClientVer")

    clients = (inbound.get("settings") or {}).get("clients") or []
    for client in clients:
        clients_total += 1
        if client.pop("flow", None) is not None:
            changes.append("убран flow у клиента " + str(client.get("email") or "без имени"))

if not changes:
    print("  изменений не требуется — конфиг уже в нужном виде")
else:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    for c in changes:
        print("  ✓ " + c)

print(f"  клиентов в конфиге: {clients_total}")
PY

say "перезапускаю Xray"
restarted=0
if command -v docker >/dev/null 2>&1; then
    name=$(docker ps --format '{{.Names}}' | grep -i xray | head -1)
    if [ -n "$name" ]; then
        docker restart "$name" >/dev/null 2>&1 && { ok "контейнер $name перезапущен"; restarted=1; }
    fi
fi
if [ "$restarted" -eq 0 ]; then
    for s in xray amnezia-xray; do
        if systemctl restart "$s" >/dev/null 2>&1; then
            ok "служба $s перезапущена"
            restarted=1
            break
        fi
    done
fi
[ "$restarted" -eq 1 ] || warn "не смог перезапустить автоматически — перезапусти Xray в AmneziaVPN"

echo
say "готово"
cat <<'EOF'
  Серверная часть исправлена. Осталось поправить клиент:

  в karing-editor.html у узла Xray поставь Flow = «нет»,
  скачай karing.json заново и обнови профиль в Karing.

  Если что-то пошло не так — откат:
    bash <(curl -fsSL https://raw.githubusercontent.com/griggsdevel/fix-xray-karing/main/fix.sh) --restore
EOF
