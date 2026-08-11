"""
JesterWoW Administration Console

This application deliberately separates read operations from write operations.

READS:
    Read-only MySQL account against AzerothCore databases.

WRITES:
    Restricted host-side helper through /run/wow-admin/helper.sock.

The web container never receives direct access to Docker's control socket.
"""

import json
import os
import socket

import pymysql

from fastapi import FastAPI
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles

from jinja2 import Environment, FileSystemLoader


###############################################################################
# Application setup
###############################################################################

app = FastAPI(
    title="JesterWoW Admin",
)

app.mount(
    "/static",
    StaticFiles(directory="/app/static"),
    name="static",
)

templates = Environment(
    loader=FileSystemLoader("/app/templates"),
    autoescape=True,
)


###############################################################################
# Database
###############################################################################

def get_db():
    """
    Open an AzerothCore database connection using the restricted read-only
    credentials supplied through /opt/wow-admin/.env.
    """

    return pymysql.connect(
        host=os.environ["WOW_DB_HOST"],
        port=int(os.environ.get("WOW_DB_PORT", "3306")),
        user=os.environ["WOW_DB_USER"],
        password=os.environ["WOW_DB_PASSWORD"],
        cursorclass=pymysql.cursors.DictCursor,
        autocommit=True,
    )


###############################################################################
# Host helper
###############################################################################

def call_helper(path: str) -> dict:
    """
    Call the restricted host-side helper over its Unix-domain socket.

    This avoids exposing /var/run/docker.sock to the web application.
    """

    sock = socket.socket(
        socket.AF_UNIX,
        socket.SOCK_STREAM,
    )

    try:
        sock.connect(
            "/run/wow-admin/helper.sock"
        )

        request = (
            f"GET {path} HTTP/1.1\r\n"
            "Host: localhost\r\n"
            "Connection: close\r\n"
            "\r\n"
        )

        sock.sendall(
            request.encode("utf-8")
        )

        response = b""

        while True:
            chunk = sock.recv(4096)

            if not chunk:
                break

            response += chunk

    finally:
        sock.close()

    raw = response.decode(
        "utf-8",
        errors="replace",
    )

    _, _, body = raw.partition(
        "\r\n\r\n"
    )

    return json.loads(body)


###############################################################################
# Dashboard
###############################################################################

@app.get(
    "/",
    response_class=HTMLResponse,
)
def dashboard():
    """
    Display overall AzerothCore statistics and recent character information.
    """

    conn = get_db()

    try:

        with conn.cursor() as cursor:

            cursor.execute("""
                SELECT COUNT(*) AS count
                FROM acore_auth.account
            """)

            account_count = cursor.fetchone()["count"]

            cursor.execute("""
                SELECT COUNT(*) AS count
                FROM acore_characters.characters
            """)

            character_count = cursor.fetchone()["count"]

            cursor.execute("""
                SELECT COUNT(*) AS count
                FROM acore_characters.characters
                WHERE online = 1
            """)

            online_count = cursor.fetchone()["count"]

            cursor.execute("""
                SELECT
                    c.guid,
                    c.name,
                    c.level,
                    c.race,
                    c.class,
                    c.money,
                    c.online,
                    a.username
                FROM acore_characters.characters AS c
                LEFT JOIN acore_auth.account AS a
                    ON a.id = c.account
                ORDER BY
                    c.online DESC,
                    c.name ASC
                LIMIT 50
            """)

            characters = cursor.fetchall()

    finally:
        conn.close()

    try:

        server_info = call_helper(
            "/server/info"
        ).get(
            "output",
            "",
        )

        helper_online = True

    except Exception as exc:

        server_info = (
            f"Helper error: {exc}"
        )

        helper_online = False

    template = templates.get_template(
        "dashboard.html"
    )

    return template.render(
        account_count=account_count,
        character_count=character_count,
        online_count=online_count,
        characters=characters,
        server_info=server_info,
        helper_online=helper_online,
    )


###############################################################################
# Accounts
###############################################################################

@app.get(
    "/accounts",
    response_class=HTMLResponse,
)
def accounts_page():
    """
    Display AzerothCore accounts.

    Account modification controls will be added after the read-only UI has
    been proven stable.
    """

    conn = get_db()

    try:

        with conn.cursor() as cursor:

            cursor.execute("""
                SELECT
                    a.id,
                    a.username,
                    a.email,
                    a.last_ip,
                    a.last_login,
                    a.locked,
                    a.failed_logins,
                    COUNT(c.guid) AS character_count
                FROM acore_auth.account AS a
                LEFT JOIN acore_characters.characters AS c
                    ON c.account = a.id
                GROUP BY
                    a.id,
                    a.username,
                    a.email,
                    a.last_ip,
                    a.last_login,
                    a.locked,
                    a.failed_logins
                ORDER BY
                    a.username
            """)

            accounts = cursor.fetchall()

    finally:
        conn.close()

    template = templates.get_template(
        "accounts.html"
    )

    return template.render(
        accounts=accounts,
    )


###############################################################################
# Characters
###############################################################################

@app.get(
    "/characters",
    response_class=HTMLResponse,
)
def characters_page():
    """
    Display all AzerothCore characters and basic character information.
    """

    conn = get_db()

    try:

        with conn.cursor() as cursor:

            cursor.execute("""
                SELECT
                    c.guid,
                    c.name,
                    c.level,
                    c.race,
                    c.class,
                    c.money,
                    c.online,
                    c.totaltime,
                    c.map,
                    c.position_x,
                    c.position_y,
                    c.position_z,
                    a.username
                FROM acore_characters.characters AS c
                LEFT JOIN acore_auth.account AS a
                    ON a.id = c.account
                ORDER BY
                    c.name
            """)

            characters = cursor.fetchall()

    finally:
        conn.close()

    template = templates.get_template(
        "characters.html"
    )

    return template.render(
        characters=characters,
    )


###############################################################################
# Server
###############################################################################

@app.get(
    "/server",
    response_class=HTMLResponse,
)
def server_page():
    """
    Display live data directly from the running AzerothCore worldserver.
    """

    try:

        server_info = call_helper(
            "/server/info"
        ).get(
            "output",
            "",
        )

        helper_online = True

    except Exception as exc:

        server_info = (
            f"Helper error: {exc}"
        )

        helper_online = False

    template = templates.get_template(
        "server.html"
    )

    return template.render(
        server_info=server_info,
        helper_online=helper_online,
    )


###############################################################################
# Audit
###############################################################################

@app.get(
    "/audit",
    response_class=HTMLResponse,
)
def audit_page():
    """
    Audit logging will be populated when administrative write operations are
    enabled.
    """

    template = templates.get_template(
        "audit.html"
    )

    return template.render(
        events=[],
    )


###############################################################################
# Health
###############################################################################

@app.get("/health")
def health():
    """
    Lightweight container health check.
    """

    return {
        "status": "ok",
    }


###############################################################################
# Character detail page
###############################################################################

from fastapi import Form
from fastapi.responses import RedirectResponse


def helper_post(path: str, payload: dict) -> dict:
    """
    POST structured JSON to the restricted host helper.
    """

    import http.client

    class UnixHTTPConnection(
        http.client.HTTPConnection
    ):

        def connect(self):
            self.sock = socket.socket(
                socket.AF_UNIX,
                socket.SOCK_STREAM,
            )

            self.sock.connect(
                "/run/wow-admin/helper.sock"
            )

    connection = UnixHTTPConnection(
        "localhost"
    )

    body = json.dumps(payload)

    connection.request(
        "POST",
        path,
        body=body,
        headers={
            "Content-Type":
                "application/json",
            "Content-Length":
                str(len(body)),
        },
    )

    response = connection.getresponse()

    data = response.read().decode(
        "utf-8",
        errors="replace",
    )

    connection.close()

    if response.status >= 400:
        raise RuntimeError(
            f"Helper returned "
            f"{response.status}: {data}"
        )

    return json.loads(data)


@app.get(
    "/characters/{guid}",
    response_class=HTMLResponse,
)
def character_detail(guid: int):

    conn = get_db()

    try:

        with conn.cursor() as cursor:

            cursor.execute(
                """
                SELECT
                    c.guid,
                    c.name,
                    c.level,
                    c.money,
                    c.online,
                    c.race,
                    c.class,
                    c.totaltime,
                    a.username
                FROM acore_characters.characters AS c
                LEFT JOIN acore_auth.account AS a
                    ON a.id = c.account
                WHERE c.guid = %s
                """,
                (guid,),
            )

            character = cursor.fetchone()

    finally:
        conn.close()

    if not character:
        return HTMLResponse(
            "Character not found",
            status_code=404,
        )

    template = templates.get_template(
        "character_detail.html"
    )

    return template.render(
        character=character,
    )


@app.post(
    "/characters/{guid}/level"
)
def character_set_level(
    guid: int,
    character: str = Form(...),
    level: int = Form(...),
):

    helper_post(
        "/character/level",
        {
            "character": character,
            "level": level,
        },
    )

    return RedirectResponse(
        url=f"/characters/{guid}",
        status_code=303,
    )


@app.post(
    "/characters/{guid}/money"
)
def character_set_money(
    guid: int,
    gold: int = Form(0),
    silver: int = Form(0),
    copper: int = Form(0),
):

    if gold < 0:
        gold = 0

    silver = max(
        0,
        min(
            silver,
            99,
        ),
    )

    copper = max(
        0,
        min(
            copper,
            99,
        ),
    )

    total_copper = (
        gold * 10000
        + silver * 100
        + copper
    )

    helper_post(
        "/character/money",
        {
            "guid": guid,
            "copper": total_copper,
        },
    )

    return RedirectResponse(
        url=f"/characters/{guid}",
        status_code=303,
    )


@app.post(
    "/characters/{guid}/reset-talents"
)
def character_reset_talents(
    guid: int,
    character: str = Form(...),
):

    helper_post(
        "/character/reset-talents",
        {
            "character": character,
        },
    )

    return RedirectResponse(
        url=f"/characters/{guid}",
        status_code=303,
    )


@app.post(
    "/characters/{guid}/rename"
)
def character_force_rename(
    guid: int,
    character: str = Form(...),
):

    helper_post(
        "/character/rename",
        {
            "character": character,
        },
    )

    return RedirectResponse(
        url=f"/characters/{guid}",
        status_code=303,
    )


@app.post(
    "/characters/{guid}/kick"
)
def character_kick(
    guid: int,
    character: str = Form(...),
):

    helper_post(
        "/character/kick",
        {
            "character": character,
            "reason": "JesterWoW Admin",
        },
    )

    return RedirectResponse(
        url=f"/characters/{guid}",
        status_code=303,
    )


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

# JESTERWOW_ADMIN_TOOLS_WEB
# Remove the old placeholder audit route before registering the functional one.
for _route in list(app.router.routes):
    if getattr(_route, "path", None) == "/audit":
        app.router.routes.remove(_route)

from admin_tools import router as _jesterwow_admin_tools_web_router
app.include_router(_jesterwow_admin_tools_web_router)
