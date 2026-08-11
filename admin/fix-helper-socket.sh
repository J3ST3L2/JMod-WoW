#!/usr/bin/env bash
set -euo pipefail

BASE="/opt/wow-admin"
SERVICE="/etc/systemd/system/wow-admin-helper.service"
DROPIN="/etc/systemd/system/wow-admin-helper.service.d/security.conf"
OLD_SOCKET="/run/wow-admin-helper.sock"
SOCKET_DIR="/run/wow-admin"
SOCKET="$SOCKET_DIR/helper.sock"

echo "==> Backing up configuration"

sudo cp -a "$SERVICE" "${SERVICE}.bak.$(date +%Y%m%d-%H%M%S)"

if [ -f "$DROPIN" ]; then
    sudo cp -a "$DROPIN" "${DROPIN}.bak.$(date +%Y%m%d-%H%M%S)"
fi

cp -a "$BASE/docker-compose.yml" \
    "$BASE/docker-compose.yml.bak.$(date +%Y%m%d-%H%M%S)"


echo "==> Updating helper systemd service"

sudo tee "$SERVICE" >/dev/null <<'EOF'
[Unit]
Description=JesterWoW AzerothCore Admin Helper
After=docker.service
Requires=docker.service

[Service]
Type=simple

WorkingDirectory=/opt/wow-admin/helper

# systemd owns this runtime directory. It is recreated automatically
# after reboot and remains a stable mount point for the web container.
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


echo "==> Updating service security/environment override"

sudo tee "$DROPIN" >/dev/null <<'EOF'
[Service]
EnvironmentFile=/etc/wow-admin-helper.env

# Uvicorn creates Unix sockets permissively by default.
# Restrict this socket to root + wowadmin.
ExecStartPost=/bin/sh -c 'for i in $(seq 1 50); do [ -S /run/wow-admin/helper.sock ] && chmod 0660 /run/wow-admin/helper.sock && chgrp wowadmin /run/wow-admin/helper.sock && exit 0; sleep 0.1; done; exit 1'
EOF


echo "==> Updating web application socket paths"

python3 - <<'PY'
from pathlib import Path

path = Path("/opt/wow-admin/web/app/main.py")
text = path.read_text()

text = text.replace(
    "/run/wow-admin-helper.sock",
    "/run/wow-admin/helper.sock",
)

path.write_text(text)
PY


echo "==> Updating Docker Compose"

python3 - <<'PY'
from pathlib import Path

path = Path("/opt/wow-admin/docker-compose.yml")
text = path.read_text()

text = text.replace(
    "/run/wow-admin-helper.sock:/run/wow-admin-helper.sock",
    "/run/wow-admin:/run/wow-admin",
)

path.write_text(text)
PY


echo "==> Reloading helper"

sudo systemctl daemon-reload

sudo systemctl restart wow-admin-helper


echo "==> Verifying new socket"

sudo ls -la /run/wow-admin

if [ ! -S "$SOCKET" ]; then
    echo "ERROR: helper socket was not created at $SOCKET"
    exit 1
fi


echo "==> Testing helper directly"

sudo curl \
    --silent \
    --show-error \
    --unix-socket "$SOCKET" \
    http://localhost/health

echo


echo "==> Validating Compose"

cd "$BASE"

docker compose config >/dev/null


echo "==> Rebuilding web application"

docker compose build

docker compose up -d


echo "==> Waiting for application startup"

sleep 3


echo "==> Verifying directory mount inside container"

docker exec wow-admin \
    ls -la /run/wow-admin


echo "==> Testing dashboard"

curl \
    --fail \
    --silent \
    --show-error \
    -o /dev/null \
    http://127.0.0.1:8090/

echo "Dashboard: OK"


echo
echo "======================================================"
echo " Permanent helper socket repair complete"
echo "======================================================"
echo
echo "Helper socket:"
echo "  /run/wow-admin/helper.sock"
echo
echo "Web:"
echo "  http://10.20.60.18:8090"
echo
