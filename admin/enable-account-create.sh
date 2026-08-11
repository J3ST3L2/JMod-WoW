#!/usr/bin/env bash
set -euo pipefail

BASE="/opt/wow-admin"
HELPER="$BASE/helper/helper.py"
WEB="$BASE/web/app/main.py"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BASE/backups/account-create-$STAMP"

mkdir -p "$BACKUP"

cp -a "$HELPER" "$BACKUP/helper.py"
cp -a "$WEB" "$BACKUP/main.py"

echo "==> Backup: $BACKUP"


###############################################################################
# Add account creation endpoint to host helper.
###############################################################################

if ! grep -q 'JESTER_ACCOUNT_CREATE_HELPER' "$HELPER"; then

cat >> "$HELPER" <<'PY'


###############################################################################
# JESTER_ACCOUNT_CREATE_HELPER
#
# Account creation deliberately goes through AzerothCore's worldserver
# console rather than writing authentication rows directly.
###############################################################################

class AccountCreateRequest(BaseModel):
    username: str = Field(min_length=1, max_length=17)
    password: str = Field(min_length=1, max_length=16)
    email: str = Field(default="", max_length=255)


def validate_account_username(value: str) -> str:
    """
    Keep account names deliberately conservative.

    AzerothCore itself handles normalization, but because this value becomes
    part of a console command we forbid whitespace and command separators.
    """
    value = value.strip()

    if not re.fullmatch(r"[A-Za-z0-9_]{1,17}", value):
        raise HTTPException(
            status_code=400,
            detail=(
                "Username must be 1-17 characters and contain only "
                "letters, numbers, or underscore."
            ),
        )

    return value


def validate_account_password(value: str) -> str:
    """
    AzerothCore currently limits account passwords to 16 characters.

    The worldserver command parser separates arguments on whitespace, so
    whitespace and control characters are intentionally rejected here.
    """
    if not value:
        raise HTTPException(
            status_code=400,
            detail="Password cannot be empty.",
        )

    if len(value) > 16:
        raise HTTPException(
            status_code=400,
            detail="Password cannot exceed 16 characters.",
        )

    if any(ch.isspace() or not ch.isprintable() for ch in value):
        raise HTTPException(
            status_code=400,
            detail="Password cannot contain spaces or control characters.",
        )

    return value


def validate_account_email(value: str) -> str:
    """
    Email is optional.

    This is intentionally lightweight validation. AzerothCore owns the
    account data rules; we mainly need to ensure the console command cannot
    be split into additional arguments.
    """
    value = value.strip()

    if not value:
        return ""

    if len(value) > 255:
        raise HTTPException(
            status_code=400,
            detail="Email cannot exceed 255 characters.",
        )

    if any(ch.isspace() or not ch.isprintable() for ch in value):
        raise HTTPException(
            status_code=400,
            detail="Email cannot contain whitespace or control characters.",
        )

    return value


@app.post("/account/create")
def create_account(request: AccountCreateRequest):
    username = validate_account_username(request.username)
    password = validate_account_password(request.password)
    email = validate_account_email(request.email)

    command = f"account create {username} {password}"

    if email:
        command += f" {email}"

    output = send_worldserver_command(command)

    return {
        "username": username.upper(),
        "created": True,
        "output": output,
    }
PY

fi


###############################################################################
# Add web POST route.
###############################################################################

if ! grep -q 'JESTER_ACCOUNT_CREATE_WEB' "$WEB"; then

cat >> "$WEB" <<'PY'


###############################################################################
# JESTER_ACCOUNT_CREATE_WEB
#
# Account creation is sent to the restricted host helper. The web process
# retains only read-only database access.
###############################################################################

from fastapi import Form as _AccountForm
from fastapi import HTTPException as _AccountHTTPException
from fastapi.responses import RedirectResponse as _AccountRedirectResponse
import time as _account_time


def _jester_account_exists(username: str) -> bool:
    """
    Verify account state through the existing read-only database connection.
    """
    conn = get_db()

    try:
        with conn.cursor() as cursor:
            cursor.execute(
                """
                SELECT id
                FROM acore_auth.account
                WHERE UPPER(username) = UPPER(%s)
                LIMIT 1
                """,
                (username,),
            )

            return cursor.fetchone() is not None

    finally:
        conn.close()


@app.post("/accounts/create")
@app.post("/account/create")
def jester_create_account(
    username: str = _AccountForm(...),
    password: str = _AccountForm(...),
    email: str = _AccountForm(""),
):
    username = username.strip()

    if not username:
        raise _AccountHTTPException(
            status_code=400,
            detail="Username cannot be empty.",
        )

    # Do this before invoking the worldserver so an existing account is never
    # silently treated as a successful create operation.
    if _jester_account_exists(username):
        raise _AccountHTTPException(
            status_code=409,
            detail=f"Account '{username}' already exists.",
        )

    helper_post(
        "/account/create",
        {
            "username": username,
            "password": password,
            "email": email.strip(),
        },
    )

    # The worldserver performs the real account creation. Verify through the
    # read-only auth DB rather than trusting console text alone.
    for _ in range(10):
        if _jester_account_exists(username):
            return _AccountRedirectResponse(
                url="/accounts",
                status_code=303,
            )

        _account_time.sleep(0.1)

    raise _AccountHTTPException(
        status_code=500,
        detail=(
            "The worldserver accepted the account-create request, "
            "but the account was not found in the authentication database."
        ),
    )
PY

fi


###############################################################################
# Validate Python before restarting anything.
###############################################################################

echo "==> Validating helper Python"

python3 -m py_compile "$HELPER"

echo "Helper Python: PASS"


echo "==> Validating web Python"

python3 -m py_compile "$WEB"

echo "Web Python: PASS"


###############################################################################
# Restart helper.
###############################################################################

echo "==> Restarting helper"

sudo systemctl restart wow-admin-helper

sleep 2

sudo systemctl is-active --quiet wow-admin-helper

echo "Helper: PASS"


###############################################################################
# Rebuild web container because main.py is copied into the image.
###############################################################################

echo "==> Rebuilding web application"

cd "$BASE"

docker compose build

docker compose up -d --force-recreate

sleep 3


###############################################################################
# Verify new routes exist.
###############################################################################

echo
echo "==> Helper routes"

grep -nE 'account/create|create_account' "$HELPER" | tail -n 10


echo
echo "==> Web routes"

grep -nE 'accounts/create|jester_create_account' "$WEB" | tail -n 10


###############################################################################
# Confirm helper remains reachable from the web container.
###############################################################################

echo
echo "==> Testing helper socket from web container"

docker exec wow-admin python -c '
import socket

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(3)
s.connect("/run/wow-admin/helper.sock")

s.sendall(
    b"GET /health HTTP/1.1\r\n"
    b"Host: localhost\r\n"
    b"Connection: close\r\n"
    b"\r\n"
)

data = b""

while True:
    try:
        chunk = s.recv(4096)
    except TimeoutError:
        break

    if not chunk:
        break

    data += chunk

s.close()

if b"200 OK" not in data or b"\"status\":\"ok\"" not in data:
    raise SystemExit("Helper health check FAILED")

print("Helper socket: PASS")
'


echo
echo "========================================================="
echo " Account creation backend installed"
echo "========================================================="
echo
echo "Open:"
echo "  http://10.20.60.18:8090/accounts"
echo
