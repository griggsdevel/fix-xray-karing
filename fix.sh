#!/usr/bin/env bash
#
# fix-xray-karing — правит серверный Xray (Reality) из AmneziaVPN,
# чтобы к нему подключался Karing и другие клиенты на sing-box.
#
# Что делает:
#   1. находит конфиг Xray — на хосте или внутри контейнера amnezia-xray;
#   2. делает резервную копию в /root/fix-xray-karing-backups;
#   3. убирает flow xtls-rprx-vision у клиентов;
#   4. ставит realitySettings.minClientVer = "1.0.0" (и убирает maxClientVer);
#   5. перезапускает контейнер Xray;
#   6. печатает, что получилось.
#
# Запуск:
#   bash <(curl -fsSL https://raw.githubusercontent.com/griggsdevel/fix-xray-karing/main/fix.sh)
#
# Откат:
#   bash <(curl -fsSL https://raw.githubusercontent.com/griggsdevel/fix-xray-karing/main/fix.sh) --restore
#
# Никаких адресов, ключей и идентификаторов внутри нет — всё берётся с сервера.

set -uo pipefail

BACKUP_DIR=/root/fix-xray-karing-backups
WORK=/tmp/fix-xray-karing-config.json
MODE=""
CFG=""
CONT=""
TS=$(date +%Y%m%d-%H%M%S)

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m  x\033[0m %s\n' "$*" >&2; }

if [ "$(id -u)" -ne 0 ]; then
    err "запусти от root (sudo -i)"
    exit 1
fi

mkdir -p "$BACKUP_DIR"

have_docker() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

find_container() {
    have_docker || return 1
    local name
    name=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i xray | head -1)
    [ -n "$name" ] && { CONT="$name"; return 0; }
    return 1
}

restart_xray() {
    local done_restart=0
    if have_docker; then
        [ -n "$CONT" ] || find_container || true
        if [ -n "$CONT" ]; then
            docker restart "$CONT" >/dev/null 2>&1 && { ok "контейнер $CONT перезапущен"; done_restart=1; }
        fi
    fi
    if [ "$done_restart" -eq 0 ]; then
        local s
        for s in xray amnezia-xray; do
            if systemctl restart "$s" >/dev/null 2>&1; then
                ok "служба $s перезапущена"
                done_restart=1
                break
            fi
        done
    fi
    [ "$done_restart" -eq 1 ] || warn "не смог перезапустить автоматически — перезапусти Xray в AmneziaVPN"
}

# ищет конфиг: сначала на хосте, потом внутри контейнера
locate_config() {
    local p
    for p in \
        /opt/amnezia/xray/config.json \
        /opt/amnezia/amnezia-xray/config.json \
        /opt/amnezia/xray/config/config.json \
        /etc/xray/config.json \
        /usr/local/etc/xray/config.json
    do
        if [ -f "$p" ]; then
            MODE=host
            CFG="$p"
            return 0
        fi
    done

    find_container || return 1

    for p in \
        /opt/amnezia/xray/config.json \
        /opt/amnezia/amnezia-xray/config.json \
        /etc/xray/config.json \
        /usr/local/etc/xray/config.json \
        /config.json
    do
        if docker exec "$CONT" test -f "$p" >/dev/null 2>&1; then
            MODE=docker
            CFG="$p"
            return 0
        fi
    done

    p=$(docker exec "$CONT" sh -c 'find / -maxdepth 4 -type f -name "*.json" 2>/dev/null | grep -v -E "^/proc|^/sys" | while read -r f; do grep -l realitySettings "$f" 2>/dev/null; done | head -1' 2>/dev/null)
    if [ -n "$p" ]; then
        MODE=docker
        CFG="$p"
        return 0
    fi
    return 1
}

pull_config() {
    if [ "$MODE" = "host" ]; then
        cp "$CFG" "$WORK"
    else
        docker cp "$CONT:$CFG" "$WORK" >/dev/null 2>&1 || return 1
    fi
}

push_config() {
    if [ "$MODE" = "host" ]; then
        cp "$WORK" "$CFG"
    else
        docker cp "$WORK" "$CONT:$CFG" >/dev/null 2>&1 || return 1
    fi
}

# ---------- откат ----------
if [ "${1:-}" = "--restore" ]; then
    meta=$(ls -1t "$BACKUP_DIR"/*.meta 2>/dev/null | head -1)
    if [ -z "$meta" ]; then
        err "резервных копий нет в $BACKUP_DIR"
        exit 1
    fi
    backup="${meta%.meta}.json"
    read -r MODE CFG CONT < "$meta"
    if [ "$MODE" = "host" ]; then
        cp "$backup" "$CFG" || { err "не удалось записать $CFG"; exit 1; }
    else
        docker cp "$backup" "$CONT:$CFG" >/dev/null 2>&1 || { err "не удалось скопировать в $CONT:$CFG"; exit 1; }
    fi
    ok "восстановлено из $(basename "$backup")"
    restart_xray
    exit 0
fi

# ---------- основная работа ----------
say "проверяю окружение"
if have_docker; then
    ok "docker работает"
else
    warn "docker недоступен — рассчитываю на обычную установку Xray"
fi

if ! command -v python3 >/dev/null 2>&1; then
    say "ставлю python3"
    (apt-get update -qq && apt-get install -y -qq python3) >/dev/null 2>&1 || { err "не удалось поставить python3"; exit 1; }
fi

say "ищу конфиг Xray"
if ! locate_config; then
    err "конфиг Xray не найден"
    echo
    echo "Что есть в /opt/amnezia:"
    ls -la /opt/amnezia 2>/dev/null || echo "  каталога нет"
    echo
    echo "Контейнеры:"
    docker ps --format '  {{.Names}} ({{.Image}})' 2>/dev/null || echo "  docker недоступен"
    exit 1
fi
if [ "$MODE" = "host" ]; then
    ok "конфиг на хосте: $CFG"
else
    ok "конфиг в контейнере $CONT: $CFG"
fi

if ! pull_config; then
    err "не удалось прочитать конфиг"
    exit 1
fi

cp "$WORK" "$BACKUP_DIR/config-$TS.json"
printf '%s %s %s\n' "$MODE" "$CFG" "$CONT" > "$BACKUP_DIR/config-$TS.meta"
ok "бэкап: $BACKUP_DIR/config-$TS.json"

say "правлю конфиг"
python3 - "$WORK" <<'PY'
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

if ! push_config; then
    err "не удалось записать конфиг обратно"
    exit 1
fi
ok "конфиг обновлён"

say "перезапускаю Xray"
restart_xray

echo
say "готово"
cat <<'EOF'
  Серверная часть исправлена. Осталось поправить клиент:

  в karing-editor.html у узла Xray поставь Flow = «нет»,
  скачай karing.json заново и обнови профиль в Karing.

  Откат:
    bash <(curl -fsSL https://raw.githubusercontent.com/griggsdevel/fix-xray-karing/main/fix.sh) --restore
EOF
