#!/usr/bin/env bash
set -euo pipefail

HELPER_DIR="/opt/wow-admin/helper"
PYTHON="$HELPER_DIR/venv/bin/python"

read -rsp "Password for FUGGO (Chris): " FUGGO_PASSWORD
echo

read -rsp "Password for JUTURNAA (Bobby): " JUTURNAA_PASSWORD
echo
echo

for password in "$FUGGO_PASSWORD" "$JUTURNAA_PASSWORD"; do
    if [ -z "$password" ]; then
        echo "ERROR: Password cannot be empty."
        exit 1
    fi

    if [ "${#password}" -gt 16 ]; then
        echo "ERROR: Passwords must be 16 characters or fewer."
        exit 1
    fi

    if [[ "$password" =~ [[:space:]] ]]; then
        echo "ERROR: Passwords cannot contain whitespace."
        exit 1
    fi
done

export FUGGO_PASSWORD
export JUTURNAA_PASSWORD

cd "$HELPER_DIR"

sudo --preserve-env=FUGGO_PASSWORD,JUTURNAA_PASSWORD \
    "$PYTHON" <<'PY'
import os
from helper import send_worldserver_command

accounts = [
    ("FUGGO", os.environ["FUGGO_PASSWORD"]),
    ("JUTURNAA", os.environ["JUTURNAA_PASSWORD"]),
]

for username, password in accounts:
    print(f"Creating {username}...")
    send_worldserver_command(f"account create {username} {password}")
    print(f"{username}: command sent")
PY

unset FUGGO_PASSWORD
unset JUTURNAA_PASSWORD

echo
echo "Verifying accounts..."

docker exec ac-database sh -lc \
'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e "
SELECT id, username
FROM acore_auth.account
WHERE username IN ('\''FUGGO'\'','\''JUTURNAA'\'')
ORDER BY username;
"'
