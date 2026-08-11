#!/usr/bin/env bash
set -euo pipefail

BASE="/opt/wow-admin"
WEB="$BASE/web"
APP="$WEB/app"
BACKUP="$BASE/backups/$(date +%Y%m%d-%H%M%S)"

echo "==> Backing up current web application to:"
echo "    $BACKUP"

mkdir -p "$BACKUP"

if [ -d "$WEB" ]; then
    cp -a "$WEB" "$BACKUP/"
fi

mkdir -p \
    "$APP/templates" \
    "$APP/static" \
    "$BASE/data"

###############################################################################
# Python requirements
###############################################################################

cat > "$WEB/requirements.txt" <<'EOF'
fastapi
uvicorn
jinja2
pymysql
httpx
python-multipart
EOF

###############################################################################
# Dockerfile
###############################################################################

cat > "$WEB/Dockerfile" <<'EOF'
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt

COPY app /app

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
EOF

###############################################################################
# Main FastAPI application
###############################################################################

cat > "$APP/main.py" <<'PY'
"""
JesterWoW Administration Console

This application deliberately separates read operations from write operations.

READS:
    Read-only MySQL account against AzerothCore databases.

WRITES:
    Restricted host-side helper through /run/wow-admin-helper.sock.

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
            "/run/wow-admin-helper.sock"
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
PY

###############################################################################
# Shared page structure
###############################################################################

cat > "$APP/templates/dashboard.html" <<'HTML'
<!doctype html>
<html lang="en">

<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">

    <title>Dashboard - JesterWoW Admin</title>

    <link
        rel="stylesheet"
        href="/static/style.css"
    >
</head>

<body>

<div class="shell">

    <aside class="sidebar">

        <div class="brand">

            <div class="logo">
                JT
            </div>

            <div class="brand-text">
                <strong>JesterWoW</strong>
                <small>Admin Console</small>
            </div>

        </div>

        <nav>
            <a class="active" href="/">Dashboard</a>
            <a href="/accounts">Accounts</a>
            <a href="/characters">Characters</a>
            <a href="/server">Server</a>
            <a href="/audit">Audit Log</a>
        </nav>

    </aside>


    <main>

        <header>

            <div>
                <h1>Dashboard</h1>
                <p>AzerothCore administration console</p>
            </div>

            <div class="status">

                {% if helper_online %}

                    <span class="dot online"></span>
                    Worldserver Online

                {% else %}

                    <span class="dot offline"></span>
                    Helper Offline

                {% endif %}

            </div>

        </header>


        <section class="cards">

            <div class="card">
                <span>Accounts</span>
                <strong>{{ account_count }}</strong>
            </div>

            <div class="card">
                <span>Characters</span>
                <strong>{{ character_count }}</strong>
            </div>

            <div class="card">
                <span>Players Online</span>
                <strong>{{ online_count }}</strong>
            </div>

        </section>


        <section class="panel">

            <div class="panel-title">
                <h2>Characters</h2>
            </div>

            <table>

                <thead>
                    <tr>
                        <th>Name</th>
                        <th>Account</th>
                        <th>Level</th>
                        <th>Gold</th>
                        <th>Status</th>
                    </tr>
                </thead>

                <tbody>

                {% for char in characters %}

                <tr>

                    <td>
                        {{ char.name }}
                    </td>

                    <td>
                        {{ char.username or "Unknown" }}
                    </td>

                    <td>
                        {{ char.level }}
                    </td>

                    <td>
                        {{ char.money // 10000 }}g
                        {{ (char.money // 100) % 100 }}s
                        {{ char.money % 100 }}c
                    </td>

                    <td>

                        {% if char.online %}

                            <span class="badge online-badge">
                                Online
                            </span>

                        {% else %}

                            <span class="badge offline-badge">
                                Offline
                            </span>

                        {% endif %}

                    </td>

                </tr>

                {% endfor %}

                </tbody>

            </table>

        </section>


        <section class="panel">

            <div class="panel-title">
                <h2>Worldserver</h2>
            </div>

            <pre>{{ server_info }}</pre>

        </section>

    </main>

</div>

</body>
</html>
HTML

###############################################################################
# Accounts page
###############################################################################

cat > "$APP/templates/accounts.html" <<'HTML'
<!doctype html>
<html lang="en">

<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">

    <title>Accounts - JesterWoW Admin</title>

    <link
        rel="stylesheet"
        href="/static/style.css"
    >
</head>

<body>

<div class="shell">

    <aside class="sidebar">

        <div class="brand">

            <div class="logo">
                JT
            </div>

            <div class="brand-text">
                <strong>JesterWoW</strong>
                <small>Admin Console</small>
            </div>

        </div>

        <nav>
            <a href="/">Dashboard</a>
            <a class="active" href="/accounts">Accounts</a>
            <a href="/characters">Characters</a>
            <a href="/server">Server</a>
            <a href="/audit">Audit Log</a>
        </nav>

    </aside>


    <main>

        <header>

            <div>
                <h1>Accounts</h1>
                <p>Player accounts and account status</p>
            </div>

            <button
                class="primary-button"
                disabled
            >
                Create Account
            </button>

        </header>


        <section class="panel">

            <table>

                <thead>
                    <tr>
                        <th>Username</th>
                        <th>Characters</th>
                        <th>Last Login</th>
                        <th>Last IP</th>
                        <th>Status</th>
                    </tr>
                </thead>

                <tbody>

                {% for account in accounts %}

                <tr>

                    <td>
                        <strong>
                            {{ account.username }}
                        </strong>
                    </td>

                    <td>
                        {{ account.character_count }}
                    </td>

                    <td>
                        {{ account.last_login or "Never" }}
                    </td>

                    <td>
                        {{ account.last_ip or "-" }}
                    </td>

                    <td>

                        {% if account.locked %}

                            <span class="badge offline-badge">
                                Locked
                            </span>

                        {% else %}

                            <span class="badge online-badge">
                                Active
                            </span>

                        {% endif %}

                    </td>

                </tr>

                {% endfor %}

                </tbody>

            </table>

        </section>

    </main>

</div>

</body>
</html>
HTML

###############################################################################
# Characters page
###############################################################################

cat > "$APP/templates/characters.html" <<'HTML'
<!doctype html>
<html lang="en">

<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">

    <title>Characters - JesterWoW Admin</title>

    <link
        rel="stylesheet"
        href="/static/style.css"
    >
</head>

<body>

<div class="shell">

    <aside class="sidebar">

        <div class="brand">

            <div class="logo">
                JT
            </div>

            <div class="brand-text">
                <strong>JesterWoW</strong>
                <small>Admin Console</small>
            </div>

        </div>

        <nav>
            <a href="/">Dashboard</a>
            <a href="/accounts">Accounts</a>
            <a class="active" href="/characters">Characters</a>
            <a href="/server">Server</a>
            <a href="/audit">Audit Log</a>
        </nav>

    </aside>


    <main>

        <header>

            <div>
                <h1>Characters</h1>
                <p>Character statistics and administration</p>
            </div>

        </header>


        <section class="panel">

            <table>

                <thead>
                    <tr>
                        <th>Name</th>
                        <th>Account</th>
                        <th>Level</th>
                        <th>Gold</th>
                        <th>Played</th>
                        <th>Status</th>
                    </tr>
                </thead>

                <tbody>

                {% for char in characters %}

                <tr>

                    <td>
                        <strong>
                            {{ char.name }}
                        </strong>
                    </td>

                    <td>
                        {{ char.username or "Unknown" }}
                    </td>

                    <td>
                        {{ char.level }}
                    </td>

                    <td>
                        {{ char.money // 10000 }}g
                        {{ (char.money // 100) % 100 }}s
                        {{ char.money % 100 }}c
                    </td>

                    <td>
                        {{ char.totaltime // 3600 }}h
                    </td>

                    <td>

                        {% if char.online %}

                            <span class="badge online-badge">
                                Online
                            </span>

                        {% else %}

                            <span class="badge offline-badge">
                                Offline
                            </span>

                        {% endif %}

                    </td>

                </tr>

                {% endfor %}

                </tbody>

            </table>

        </section>

    </main>

</div>

</body>
</html>
HTML

###############################################################################
# Server page
###############################################################################

cat > "$APP/templates/server.html" <<'HTML'
<!doctype html>
<html lang="en">

<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">

    <title>Server - JesterWoW Admin</title>

    <link
        rel="stylesheet"
        href="/static/style.css"
    >
</head>

<body>

<div class="shell">

    <aside class="sidebar">

        <div class="brand">

            <div class="logo">
                JT
            </div>

            <div class="brand-text">
                <strong>JesterWoW</strong>
                <small>Admin Console</small>
            </div>

        </div>

        <nav>
            <a href="/">Dashboard</a>
            <a href="/accounts">Accounts</a>
            <a href="/characters">Characters</a>
            <a class="active" href="/server">Server</a>
            <a href="/audit">Audit Log</a>
        </nav>

    </aside>


    <main>

        <header>

            <div>
                <h1>Server</h1>
                <p>Live AzerothCore status and controls</p>
            </div>

            <div class="status">

                {% if helper_online %}

                    <span class="dot online"></span>
                    Online

                {% else %}

                    <span class="dot offline"></span>
                    Offline

                {% endif %}

            </div>

        </header>


        <section class="panel">

            <div class="panel-title">
                <h2>Worldserver Information</h2>
            </div>

            <pre>{{ server_info }}</pre>

        </section>


        <section class="panel">

            <div class="panel-title">
                <h2>Server Announcement</h2>
            </div>

            <div class="form-area">

                <input
                    type="text"
                    placeholder="Message to all players"
                    disabled
                >

                <button
                    class="primary-button"
                    disabled
                >
                    Announce
                </button>

                <small>
                    Write operations will be enabled in the next phase.
                </small>

            </div>

        </section>

    </main>

</div>

</body>
</html>
HTML

###############################################################################
# Audit page
###############################################################################

cat > "$APP/templates/audit.html" <<'HTML'
<!doctype html>
<html lang="en">

<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">

    <title>Audit Log - JesterWoW Admin</title>

    <link
        rel="stylesheet"
        href="/static/style.css"
    >
</head>

<body>

<div class="shell">

    <aside class="sidebar">

        <div class="brand">

            <div class="logo">
                JT
            </div>

            <div class="brand-text">
                <strong>JesterWoW</strong>
                <small>Admin Console</small>
            </div>

        </div>

        <nav>
            <a href="/">Dashboard</a>
            <a href="/accounts">Accounts</a>
            <a href="/characters">Characters</a>
            <a href="/server">Server</a>
            <a class="active" href="/audit">Audit Log</a>
        </nav>

    </aside>


    <main>

        <header>

            <div>
                <h1>Audit Log</h1>
                <p>Administrative activity</p>
            </div>

        </header>


        <section class="panel">

            <div class="empty-state">

                <h2>No audit events yet</h2>

                <p>
                    Account and character changes will appear here once
                    administrative write operations are enabled.
                </p>

            </div>

        </section>

    </main>

</div>

</body>
</html>
HTML

###############################################################################
# Styling
###############################################################################

cat > "$APP/static/style.css" <<'CSS'
* {
    box-sizing: border-box;
}

html,
body {
    margin: 0;
    min-height: 100%;
}

body {
    font-family:
        Inter,
        system-ui,
        -apple-system,
        BlinkMacSystemFont,
        "Segoe UI",
        sans-serif;

    color: #eaf6ff;

    background:
        radial-gradient(
            circle at 15% 10%,
            rgba(0, 217, 255, 0.16),
            transparent 30%
        ),
        radial-gradient(
            circle at 90% 85%,
            rgba(255, 0, 196, 0.12),
            transparent 30%
        ),
        #050814;
}

.shell {
    min-height: 100vh;

    display: grid;

    grid-template-columns:
        240px
        minmax(0, 1fr);
}

.sidebar {
    padding: 24px;

    background:
        rgba(3, 7, 18, 0.94);

    border-right:
        1px solid
        rgba(0, 230, 255, 0.14);
}

.brand {
    display: flex;
    align-items: center;
    gap: 12px;
    margin-bottom: 42px;
}

.logo {
    width: 48px;
    height: 48px;

    display: grid;
    place-items: center;

    border-radius: 13px;

    font-size: 18px;
    font-weight: 900;

    background:
        linear-gradient(
            135deg,
            #00eaff,
            #7d45ff,
            #ff00ba
        );

    box-shadow:
        0 0 25px
        rgba(0, 225, 255, 0.32);
}

.brand-text strong {
    display: block;
    font-size: 18px;
}

.brand-text small {
    color: #8296b2;
}

nav {
    display: grid;
    gap: 7px;
}

nav a {
    padding: 12px 14px;
    border-radius: 8px;

    color: #91a5c0;

    text-decoration: none;
}

nav a:hover,
nav a.active {
    color: white;

    background:
        rgba(0, 229, 255, 0.08);

    box-shadow:
        inset 3px 0 #00e5ff;
}

main {
    padding: 34px;
}

header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 20px;

    margin-bottom: 28px;
}

h1 {
    margin: 0;
    font-size: 30px;
}

header p {
    margin: 7px 0 0;
    color: #8194ad;
}

.status {
    color: #abc0d8;
}

.dot {
    width: 10px;
    height: 10px;

    display: inline-block;

    margin-right: 7px;

    border-radius: 50%;
}

.dot.online {
    background: #00f5a0;

    box-shadow:
        0 0 12px #00f5a0;
}

.dot.offline {
    background: #ff477e;

    box-shadow:
        0 0 10px
        rgba(255, 71, 126, 0.7);
}

.cards {
    display: grid;

    grid-template-columns:
        repeat(
            3,
            minmax(180px, 1fr)
        );

    gap: 18px;

    margin-bottom: 28px;
}

.card,
.panel {
    background:
        rgba(12, 19, 38, 0.82);

    border:
        1px solid
        rgba(0, 225, 255, 0.12);

    border-radius: 14px;

    box-shadow:
        0 10px 30px
        rgba(0, 0, 0, 0.24);
}

.card {
    padding: 22px;
}

.card span {
    display: block;
    margin-bottom: 8px;
    color: #8296b2;
}

.card strong {
    font-size: 34px;
}

.panel {
    margin-bottom: 22px;
    overflow: hidden;
}

.panel-title {
    padding: 18px 20px;

    border-bottom:
        1px solid
        rgba(255, 255, 255, 0.07);
}

.panel-title h2 {
    margin: 0;
    font-size: 18px;
}

table {
    width: 100%;
    border-collapse: collapse;
}

th,
td {
    padding: 14px 18px;
    text-align: left;
}

th {
    color: #7387a4;

    font-size: 12px;

    text-transform: uppercase;
}

tbody tr {
    border-top:
        1px solid
        rgba(255, 255, 255, 0.04);
}

tbody tr:hover {
    background:
        rgba(0, 225, 255, 0.03);
}

.badge {
    padding: 5px 9px;

    border-radius: 20px;

    font-size: 12px;
}

.online-badge {
    color: #4dffc3;

    background:
        rgba(0, 245, 160, 0.12);
}

.offline-badge {
    color: #879ab5;

    background:
        rgba(130, 150, 180, 0.10);
}

pre {
    margin: 0;

    padding: 20px;

    overflow: auto;

    color: #b6cadf;

    line-height: 1.5;

    white-space: pre-wrap;

    font-family:
        "Cascadia Code",
        Consolas,
        monospace;
}

.primary-button {
    border: 0;

    border-radius: 9px;

    padding: 11px 18px;

    color: white;

    font-weight: 700;

    cursor: pointer;

    background:
        linear-gradient(
            135deg,
            #00cfff,
            #7950ff
        );

    box-shadow:
        0 0 18px
        rgba(0, 207, 255, 0.18);
}

.primary-button:disabled {
    opacity: 0.45;
    cursor: not-allowed;
}

.form-area {
    padding: 20px;

    display: grid;

    gap: 12px;
}

.form-area input {
    width: 100%;
    max-width: 600px;

    padding: 12px 14px;

    border-radius: 8px;

    border:
        1px solid
        rgba(0, 225, 255, 0.15);

    background: #080e20;

    color: white;
}

.form-area small {
    color: #7488a4;
}

.empty-state {
    padding: 60px 30px;

    text-align: center;

    color: #8296b2;
}

.empty-state h2 {
    color: #eaf6ff;
}

@media (max-width: 800px) {

    .shell {
        grid-template-columns: 1fr;
    }

    .sidebar {
        display: none;
    }

    .cards {
        grid-template-columns: 1fr;
    }

}
CSS

###############################################################################
# Compose configuration
###############################################################################

cat > "$BASE/docker-compose.yml" <<'YAML'
services:
  web:
    build:
      context: ./web

    container_name: wow-admin
    restart: unless-stopped

    env_file:
      - .env

    ports:
      - "8090:8080"

    volumes:
      - /run/wow-admin-helper.sock:/run/wow-admin-helper.sock

    group_add:
      - "987"

    networks:
      - ac-network

networks:
  ac-network:
    external: true
    name: azerothcore-wotlk_ac-network
YAML

###############################################################################
# Validate and deploy
###############################################################################

echo
echo "==> Validating Docker Compose..."

cd "$BASE"

docker compose config >/dev/null

echo "    Compose validation passed."

echo
echo "==> Building JesterWoW Admin..."

docker compose build

echo
echo "==> Starting JesterWoW Admin..."

docker compose up -d

echo
echo "==> Waiting for application startup..."

sleep 3

echo
echo "==> Container status"

docker compose ps

echo
echo "==> Recent application logs"

docker logs wow-admin --tail 30

###############################################################################
# Route tests
###############################################################################

echo
echo "==> Testing routes"

for route in \
    "/" \
    "/accounts" \
    "/characters" \
    "/server" \
    "/audit" \
    "/health"
do

    CODE="$(curl \
        -s \
        -o /dev/null \
        -w '%{http_code}' \
        "http://127.0.0.1:8090${route}")"

    printf "    %-15s %s\n" "$route" "$CODE"

done

echo
echo "======================================================"
echo " JesterWoW Admin update complete"
echo "======================================================"
echo
echo " Open:"
echo
echo "   http://10.20.60.18:8090"
echo
echo "   http://10.20.60.18:8090/accounts"
echo "   http://10.20.60.18:8090/characters"
echo "   http://10.20.60.18:8090/server"
echo "   http://10.20.60.18:8090/audit"
echo
echo " Backup:"
echo "   $BACKUP"
echo
