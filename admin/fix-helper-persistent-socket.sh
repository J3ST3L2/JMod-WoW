#!/usr/bin/env bash
set -euo pipefail

BASE="/opt/wow-admin"
RUN_DIR="$BASE/run"
HOST_SOCKET="$RUN_DIR/helper.sock"

SERVICE="/etc/systemd/system/wow-admin-helper.service"
DROPIN="/etc/systemd/system/wow-admin-helper.service.d/security.conf"
COMPOSE="$BASE/docker-compose.yml"

STAMP="$(date +%Y%m%d-%H%M%S)"

echo "==> Creating backups"

sudo cp -a "$SERVICE" "$SERVICE.bak.$STAMP"

if [ -f "$DROPIN" ]; then
    sudo cp -a "$DROPIN" "$DROPIN.bak.$STAMP"
fi

cp -a "$COMPOSE" "$COMPOSE.bak.$STAMP"


###############################################################################
# Create a persistent host directory.
#
# Unlike systemd RuntimeDirectory, this directory is NOT deleted when the
# helper service restarts. Docker therefore keeps a stable directory mount.
###############################################################################

echo "==> Creating persistent socket directory"

sudo mkdir -p "$RUN_DIR"

sudo chown root:wowadmin "$RUN_DIR"

sudo chmod 0770 "$RUN_DIR"

sudo rm -f "$HOST_SOCKET"


###############################################################################
# Replace the helper service.
###############################################################################

echo "==> Updating helper service"

sudo tee "$SERVICE" >/dev/null <<'EOF'
[Unit]
Description=JesterWoW AzerothCore Admin Helper
After=docker.service
Requires=docker.service

[Service]
Type=simple

WorkingDirectory=/opt/wow-admin/helper

# Remove only the socket itself.
#
# IMPORTANT:
# /opt/wow-admin/run remains persistent across service restarts so Docker
# never loses the directory that it has bind-mounted.
ExecStartPre=/usr/bin/rm -f /opt/wow-admin/run/helper.sock

ExecStart=/opt/wow-admin/helper/venv/bin/uvicorn \
    helper:app \
    --app-dir /opt/wow-admin/helper \
    --uds /opt/wow-admin/run/helper.sock

Restart=on-failure
RestartSec=3

User=root
Group=wowadmin

[Install]
WantedBy=multi-user.target
EOF


###############################################################################
# Keep environment and socket permissions.
###############################################################################

sudo tee "$DROPIN" >/dev/null <<'EOF'
[Service]
EnvironmentFile=/etc/wow-admin-helper.env

ExecStartPost=/bin/sh -c 'for i in $(seq 1 50); do [ -S /opt/wow-admin/run/helper.sock ] && chmod 0660 /opt/wow-admin/run/helper.sock && chgrp wowadmin /opt/wow-admin/run/helper.sock && exit 0; sleep 0.1; done; exit 1'
EOF


###############################################################################
# Update Docker Compose.
#
# Host:
#     /opt/wow-admin/run
#
# Container:
#     /run/wow-admin
#
# The Python application DOES NOT need another path change.
###############################################################################

echo "==> Updating Docker Compose"

python3 - <<'PY'
from pathlib import Path

path = Path("/opt/wow-admin/docker-compose.yml")
text = path.read_text()

text = text.replace(
    "/run/wow-admin:/run/wow-admin",
    "/opt/wow-admin/run:/run/wow-admin",
)

text = text.replace(
    "/run/wow-admin-helper.sock:/run/wow-admin-helper.sock",
    "/opt/wow-admin/run:/run/wow-admin",
)

text = text.replace(
    "/run/wow-admin/helper.sock:/run/wow-admin/helper.sock",
    "/opt/wow-admin/run:/run/wow-admin",
)

path.write_text(text)
PY


###############################################################################
# Restart helper.
###############################################################################

echo "==> Reloading systemd"

sudo systemctl daemon-reload

sudo systemctl restart wow-admin-helper

sleep 2


echo
echo "==> Host socket"

sudo ls -lan "$RUN_DIR"

if [ ! -S "$HOST_SOCKET" ]; then
    echo
    echo "ERROR: helper.sock does not exist."
    exit 1
fi


###############################################################################
# Direct host-side helper test.
###############################################################################

echo
echo "==> Testing helper on host"

sudo curl \
    --fail \
    --silent \
    --show-error \
    --unix-socket "$HOST_SOCKET" \
    http://localhost/health

echo


###############################################################################
# Recreate web container with corrected directory mount.
###############################################################################

echo
echo "==> Validating Compose"

cd "$BASE"

docker compose config >/dev/null

echo "Compose validation: PASS"


echo
echo "==> Recreating web container"

docker compose up -d --force-recreate

sleep 3


###############################################################################
# Verify socket inside container.
###############################################################################

echo
echo "==> Socket inside web container"

docker exec wow-admin \
    ls -lan /run/wow-admin


###############################################################################
# Test socket directly from web container.
###############################################################################

echo
echo "==> Testing helper from web container"

docker exec wow-admin python -c '
import socket

path="/run/wow-admin/helper.sock"

s=socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(3)
s.connect(path)

s.sendall(
    b"GET /health HTTP/1.1\r\n"
    b"Host: localhost\r\n"
    b"Connection: close\r\n"
    b"\r\n"
)

data=b""

while True:
    try:
        chunk=s.recv(4096)
    except TimeoutError:
        break

    if not chunk:
        break

    data += chunk

s.close()

text=data.decode(errors="replace")

print(text)

if "\"status\":\"ok\"" not in text:
    raise SystemExit("Helper health check failed.")
'


###############################################################################
# THE IMPORTANT TEST:
#
# Restart only the helper. The persistent directory must survive.
###############################################################################

echo
echo "==> Restarting helper to test socket persistence"

sudo systemctl restart wow-admin-helper

sleep 2


echo
echo "==> Socket after helper restart"

sudo ls -lan "$RUN_DIR"


echo
echo "==> Testing web container AFTER helper restart"

docker exec wow-admin python -c '
import socket

path="/run/wow-admin/helper.sock"

s=socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(3)
s.connect(path)

s.sendall(
    b"GET /health HTTP/1.1\r\n"
    b"Host: localhost\r\n"
    b"Connection: close\r\n"
    b"\r\n"
)

data=b""

while True:
    try:
        chunk=s.recv(4096)
    except TimeoutError:
        break

    if not chunk:
        break

    data += chunk

s.close()

if b"\"status\":\"ok\"" not in data:
    raise SystemExit("FAILED after helper restart.")

print("Helper reachable after restart: PASS")
'


###############################################################################
# Final application tests.
###############################################################################

echo
echo "==> Testing web pages"

for route in \
    "/" \
    "/characters" \
    "/characters/1"
do

    CODE="$(
        curl \
            -s \
            -o /dev/null \
            -w '%{http_code}' \
            "http://127.0.0.1:8090$route"
    )"

    printf "    %-22s %s\n" "$route" "$CODE"

done


echo
echo "============================================================"
echo " Persistent helper socket repair complete"
echo "============================================================"
echo
echo "Host directory:"
echo "  /opt/wow-admin/run"
echo
echo "Host socket:"
echo "  /opt/wow-admin/run/helper.sock"
echo
echo "Container socket:"
echo "  /run/wow-admin/helper.sock"
echo
echo "Open:"
echo "  http://10.20.60.18:8090/characters/1"
echo
