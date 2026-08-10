#!/usr/bin/env bash
set -euo pipefail

HELPER_DIR="/opt/wow-admin/helper"
PYTHON="$HELPER_DIR/venv/bin/python"

echo "Creating AzerothCore accounts: CHRIS and BOBBY"
echo

read -rsp "Password for CHRIS: " CHRIS_PASSWORD
echo

read -rsp "Password for BOBBY: " BOBBY_PASSWORD
echo
echo

# AzerothCore's console parser does not play nicely with whitespace.
for password in "$CHRIS_PASSWORD" "$BOBBY_PASSWORD"; do
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

export CHRIS_PASSWORD
export BOBBY_PASSWORD

cd "$HELPER_DIR"

sudo --preserve-env=CHRIS_PASSWORD,BOBBY_PASSWORD \
    "$PYTHON" <<'PY'
import os
import sys

from helper import send_worldserver_command


accounts = [
    ("CHRIS", os.environ["CHRIS_PASSWORD"]),
    ("BOBBY", os.environ["BOBBY_PASSWORD"]),
]


for username, password in accounts:
    print(f"Creating {username}...")

    # Do not print the returned console output because it may contain
    # the original command, including the password.
    send_worldserver_command(
        f"account create {username} {password}"
    )

    print(f"{username}: command sent")


print()
print("Account creation commands completed.")
PY

unset CHRIS_PASSWORD
unset BOBBY_PASSWORD


echo
echo "Verifying accounts in AzerothCore..."
echo

docker exec ac-database sh -lc \
'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e "
SELECT id, username
FROM acore_auth.account
WHERE username IN ('\''CHRIS'\'','\''BOBBY'\'')
ORDER BY username;
"'

echo
echo "Done."
