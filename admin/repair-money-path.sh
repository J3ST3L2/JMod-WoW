#!/usr/bin/env bash
set -euo pipefail

BASE="/opt/wow-admin"
APP="$BASE/web/app/main.py"
COMPOSE="$BASE/docker-compose.yml"
SERVICE="/etc/systemd/system/wow-admin-helper.service"
DROPIN="/etc/systemd/system/wow-admin-helper.service.d/security.conf"

echo "==> Creating backups"

STAMP="$(date +%Y%m%d-%H%M%S)"

cp -a "$APP" "$APP.bak.$STAMP"
cp -a "$COMPOSE" "$COMPOSE.bak.$STAMP"
sudo cp -a "$SERVICE" "$SERVICE.bak.$STAMP"

if [ -f "$DROPIN" ]; then
    sudo cp -a "$DROPIN" "$DROPIN.bak.$STAMP"
fi


###############################################################################
# Create a stable runtime DIRECTORY instead of bind-mounting the socket file.
###############################################################################

echo "==> Updating helper systemd service"

sudo tee "$SERVICE" >/dev/null <<'EOF'
[Unit]
Description=JesterWoW AzerothCore Admin Helper
After=docker.service
Requires=docker.service

[Service]
Type=simple

WorkingDirectory=/opt/wow-admin/helper

# Creates /run/wow-admin automatically.
#
# We mount this DIRECTORY into the web container instead of mounting the
# socket file directly. That means helper restarts can recreate helper.sock
# without leaving the web container attached to an obsolete socket inode.
RuntimeDirectory=wow-admin
RuntimeDirectoryMode=0770

ExecStart=/opt/wow-admin/helper/venv/bin/uvicorn \
    helper:app \
    --app-dir /opt/wow-admin/helper \
    --uds /run/wow-admin/helper.sock

Restart=on-failure
RestartSec=3

User=root
Group=wowadmin

[Install]
WantedBy=multi-user.target
EOF


echo "==> Updating helper override"

sudo tee "$DROPIN" >/dev/null <<'EOF'
[Service]
EnvironmentFile=/etc/wow-admin-helper.env

# Restrict helper socket access to root + wowadmin.
ExecStartPost=/bin/sh -c 'for i in $(seq 1 50); do [ -S /run/wow-admin/helper.sock ] && chmod 0660 /run/wow-admin/helper.sock && chgrp wowadmin /run/wow-admin/helper.sock && exit 0; sleep 0.1; done; exit 1'
EOF


###############################################################################
# Change all web-app references to the new stable socket path.
###############################################################################

echo "==> Updating web application socket path"

python3 - <<'PY'
from pathlib import Path

p = Path("/opt/wow-admin/web/app/main.py")
text = p.read_text()

text = text.replace(
    "/run/wow-admin-helper.sock",
    "/run/wow-admin/helper.sock",
)

p.write_text(text)
PY


###############################################################################
# Replace the socket-file bind mount with a directory bind mount.
###############################################################################

echo "==> Updating Docker Compose mount"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("/opt/wow-admin/docker-compose.yml")
text = p.read_text()

text = text.replace(
    "/run/wow-admin-helper.sock:/run/wow-admin-helper.sock",
    "/run/wow-admin:/run/wow-admin",
)

# Also handle a previous partially-updated configuration.
text = text.replace(
    "/run/wow-admin/helper.sock:/run/wow-admin/helper.sock",
    "/run/wow-admin:/run/wow-admin",
)

p.write_text(text)
PY


###############################################################################
# Restart helper and verify its socket.
###############################################################################

echo "==> Restarting helper"

sudo systemctl daemon-reload
sudo systemctl restart wow-admin-helper

sleep 1

echo
echo "==> Helper status"

sudo systemctl --no-pager --full status wow-admin-helper | head -n 20

echo
echo "==> Host socket"

sudo ls -ln /run/wow-admin/helper.sock


###############################################################################
# Test helper directly.
###############################################################################

echo
echo "==> Direct helper test"

sudo curl \
    --fail \
    --silent \
    --show-error \
    --unix-socket /run/wow-admin/helper.sock \
    http://localhost/server/info >/dev/null

echo "Direct helper test: PASS"


###############################################################################
# Recreate web container so it receives the DIRECTORY mount.
###############################################################################

echo
echo "==> Validating Compose"

cd "$BASE"

docker compose config >/dev/null

echo "Compose: PASS"

echo
echo "==> Rebuilding/recreating web container"

docker compose build

docker compose up -d --force-recreate

sleep 3


###############################################################################
# Verify the directory/socket from INSIDE the web container.
###############################################################################

echo
echo "==> Socket visible inside web container"

docker exec wow-admin ls -ln /run/wow-admin/helper.sock


###############################################################################
# Test Unix-socket access from inside the web container.
###############################################################################

echo
echo "==> Testing helper from inside web container"

docker exec wow-admin python - <<'PY'
import socket

path = "/run/wow-admin/helper.sock"

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(path)

request = (
    "GET /health HTTP/1.1\r\n"
    "Host: localhost\r\n"
    "Connection: close\r\n"
    "\r\n"
)

s.sendall(request.encode())

data = b""

while True:
    chunk = s.recv(4096)
    if not chunk:
        break
    data += chunk

s.close()

text = data.decode("utf-8", errors="replace")

print(text)

if '"status":"ok"' not in text:
    raise SystemExit("Helper health response was not OK.")
PY


###############################################################################
# Test web routes.
###############################################################################

echo
echo "==> Testing web routes"

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
            "http://127.0.0.1:8090${route}"
    )"

    printf "%-24s %s\n" "$route" "$CODE"
done


###############################################################################
# Critical restart test.
#
# This recreates helper.sock. The web container should STILL work afterward
# because it now sees the enclosing directory, not a stale mounted socket.
###############################################################################

echo
echo "==> Testing helper restart behavior"

sudo systemctl restart wow-admin-helper

sleep 2

docker exec wow-admin python - <<'PY'
import socket

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect("/run/wow-admin/helper.sock")

s.sendall(
    b"GET /health HTTP/1.1\r\n"
    b"Host: localhost\r\n"
    b"Connection: close\r\n"
    b"\r\n"
)

data = b""

while True:
    chunk = s.recv(4096)
    if not chunk:
        break
    data += chunk

s.close()

if b'"status":"ok"' not in data:
    raise SystemExit("FAILED after helper restart")

print("Helper reachable after restart: PASS")
PY


echo
echo "======================================================"
echo " Money/helper socket repair completed successfully"
echo "======================================================"
echo
echo "Open:"
echo "  http://10.20.60.18:8090/characters/1"
echo
