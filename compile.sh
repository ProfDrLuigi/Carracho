#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

WEBADMIN_DIR="$ROOT/ServerLinux/Webinterface"
WEBADMIN_BUILD="$WEBADMIN_DIR/scripts/linux-build-phase.sh"
WEBADMIN_STAGE="$ROOT/.build/linux/libexec/carracho"

LIVE_ETC="/opt/carracho/etc"
HTTP_ENV="$LIVE_ETC/carracho-server.env"
SYSTEMD_DROPIN_DIR="/etc/systemd/system/carracho.service.d"
SYSTEMD_DROPIN="$SYSTEMD_DROPIN_DIR/webadmin.conf"

merge_json_config() {
    local defaults="$1"
    local live="$2"
    local output="$3"

    if [ ! -f "$defaults" ]; then
        echo "error: Default config fehlt: $defaults" >&2
        return 1
    fi

    if [ ! -f "$live" ]; then
        echo "==> Keine Live-Konfiguration vorhanden, verwende Defaults: $defaults"
        return 0
    fi

    echo "==> Merge config:"
    echo "    defaults: $defaults"
    echo "    live:     $live"
    echo "    output:   $output"

    python3 - "$defaults" "$live" "$output" <<'PY'
import json
import os
import sys
import tempfile

defaults_path, live_path, output_path = sys.argv[1:4]

with open(defaults_path, "r", encoding="utf-8") as f:
    defaults = json.load(f)

with open(live_path, "r", encoding="utf-8") as f:
    live = json.load(f)

def merge(default, current):
    if isinstance(default, dict) and isinstance(current, dict):
        result = dict(default)
        for key, value in current.items():
            if key in result:
                result[key] = merge(result[key], value)
            else:
                result[key] = value
        return result
    return current

merged = merge(defaults, live)

directory = os.path.dirname(output_path)
os.makedirs(directory, exist_ok=True)

fd, tmp = tempfile.mkstemp(prefix=".carracho-config-", dir=directory, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(merged, f, ensure_ascii=False, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, output_path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
}

ensure_http_admin_token() {
    install -d -m 0755 "$LIVE_ETC"

    local existing=""
    if [ -f "$HTTP_ENV" ]; then
        existing="$(
            sed -n 's/^CARRACHO_HTTP_ADMIN_TOKEN=//p' "$HTTP_ENV" \
            | head -n 1
        )"
    fi

    if [ "${#existing}" -ge 24 ]; then
        echo "==> HTTP admin token vorhanden"
    else
        echo "==> Erzeuge persistenten HTTP admin token"

        local token
        if command -v openssl >/dev/null 2>&1; then
            token="$(openssl rand -hex 32)"
        else
            token="$(
                python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
            )"
        fi

        umask 077
        cat > "$HTTP_ENV" <<EOF
CARRACHO_HTTP_ADMIN_TOKEN=$token
EOF
        chmod 0600 "$HTTP_ENV"
        chown root:root "$HTTP_ENV"
    fi

    install -d -m 0755 "$SYSTEMD_DROPIN_DIR"

    cat > "$SYSTEMD_DROPIN" <<EOF
[Service]
EnvironmentFile=$HTTP_ENV
EOF

    chmod 0644 "$SYSTEMD_DROPIN"

    echo "==> systemd EnvironmentFile:"
    echo "    $HTTP_ENV"
    echo "==> systemd Drop-in:"
    echo "    $SYSTEMD_DROPIN"

    # Migration von der früher dokumentierten Zwei-Service-Variante.
    # Der WebAdmin wird inzwischen direkt von carracho-server als Child verwaltet.
    if [ -f /etc/systemd/system/carracho-webadmin.service ]; then
        echo "==> Entferne alten separaten carracho-webadmin.service"
        systemctl disable --now carracho-webadmin.service >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/carracho-webadmin.service
    fi

    systemctl daemon-reload
}

show_failure_log() {
    echo
    echo "================ carracho.service journal ================"
    journalctl -u carracho.service -n 80 --no-pager || true
    echo "==========================================================="
}

echo "==> Stopping Carracho server"
systemctl stop carracho.service || true

echo "==> Building Carracho server"
bash ServerLinux/build.sh

echo "==> Building bundled WebAdmin"
if [ ! -x "$WEBADMIN_BUILD" ]; then
    echo "error: WebAdmin build script not found or not executable:" >&2
    echo "       $WEBADMIN_BUILD" >&2
    exit 1
fi

bash "$WEBADMIN_BUILD" "$WEBADMIN_STAGE"

if [ ! -x "$WEBADMIN_STAGE/carracho-web-admin-helper" ]; then
    echo "error: bundled WebAdmin helper was not created:" >&2
    echo "       $WEBADMIN_STAGE/carracho-web-admin-helper" >&2
    exit 1
fi

echo "==> Building Carracho tracker"
bash TrackerLinux/build.sh

merge_json_config \
    ".build/linux/etc/carracho-server.json" \
    "/opt/carracho/etc/carracho-server.json" \
    ".build/linux/etc/carracho-server.json"

if [ -f ".build/linux/etc/carracho-bot.json" ]; then
    merge_json_config \
        ".build/linux/etc/carracho-bot.json" \
        "/opt/carracho/etc/carracho-bot.json" \
        ".build/linux/etc/carracho-bot.json"
fi

echo "==> Verifying HTTP admin config in staged server JSON"
python3 - <<'PY'
import json
import sys

path = ".build/linux/etc/carracho-server.json"
with open(path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

http_admin = cfg.get("httpAdmin")
if not isinstance(http_admin, dict):
    print("error: httpAdmin fehlt in " + path, file=sys.stderr)
    sys.exit(1)

if http_admin.get("enabled"):
    port = http_admin.get("port", 6780)
    bind = http_admin.get("bind", "127.0.0.1")
    print(f"    enabled=true bind={bind} port={port}")
else:
    print("    enabled=false")
PY

echo "==> Deploying to /opt/carracho"
cp -rf .build/linux/* /opt/carracho
rm -rf .build
chown pi:pi -R /opt/carracho

echo "==> Configuring WebAdmin token/systemd"
ensure_http_admin_token

echo "==> Starting Carracho server"
if ! systemctl start carracho.service; then
    show_failure_log
    exit 1
fi

sleep 1

if ! systemctl is-active --quiet carracho.service; then
    echo "error: carracho.service läuft nach dem Start nicht." >&2
    show_failure_log
    exit 1
fi

systemctl status carracho.service --no-pager

echo "==> Starting Carracho tracker"
systemctl start carracho-tracker.service
sleep 1
systemctl status carracho-tracker.service --no-pager

echo "==> Checking HTTP Admin API"
TOKEN="$(sed -n 's/^CARRACHO_HTTP_ADMIN_TOKEN=//p' "$HTTP_ENV" | head -n1)"

if command -v curl >/dev/null 2>&1; then
    if curl --silent --show-error --fail \
        -H "Authorization: Bearer $TOKEN" \
        http://127.0.0.1:6780/api/v1/status >/tmp/carracho-http-status.json; then
        echo "    HTTP API  : OK (127.0.0.1:6780)"
        cat /tmp/carracho-http-status.json
        echo
    else
        echo "warning: HTTP API auf 127.0.0.1:6780 antwortet noch nicht." >&2
    fi

    if curl --silent --show-error --fail \
        http://127.0.0.1:6781/healthz >/dev/null; then
        echo "    Web Admin : OK (127.0.0.1:6781)"
    else
        echo "warning: Web Admin auf 127.0.0.1:6781 antwortet noch nicht." >&2
    fi
fi

echo
echo "==> Done"
echo "WebAdmin helper:"
echo "    /opt/carracho/libexec/carracho/carracho-web-admin-helper"
echo "Token-Datei:"
echo "    $HTTP_ENV"
