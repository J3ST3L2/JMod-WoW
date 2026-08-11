#!/usr/bin/env bash
set -euo pipefail

BASE="/opt/wow-admin"
HELPER="$BASE/helper/helper.py"
WEB="$BASE/web/app"
BACKUP="$BASE/backups/character-actions-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP"

cp -a "$HELPER" "$BACKUP/"
cp -a "$WEB/main.py" "$BACKUP/"
cp -a "$WEB/templates" "$BACKUP/"

###############################################################################
# Replace helper with expanded version
###############################################################################

cat > "$HELPER" <<'PY'
"""
JesterWoW Host Helper

This helper is the only component allowed to communicate directly with
the Docker daemon and the AzerothCore worldserver console.

The web application does NOT receive Docker socket access.

All exposed operations are explicitly allow-listed and validated.
"""

import os
import re
import time

import docker
import pymysql

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field


CONTAINER_NAME = "ac-worldserver"

ANSI_RE = re.compile(
    r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])"
)

NAME_RE = re.compile(
    r"^[A-Za-z0-9_-]{2,32}$"
)


app = FastAPI(
    title="JesterWoW Host Helper",
    docs_url=None,
    redoc_url=None,
)


###############################################################################
# Models
###############################################################################

class CharacterLevelRequest(BaseModel):
    character: str
    level: int = Field(ge=1, le=80)


class CharacterMoneyRequest(BaseModel):
    guid: int = Field(gt=0)
    copper: int = Field(ge=0, le=2147483647)


class CharacterNameRequest(BaseModel):
    character: str


class KickRequest(BaseModel):
    character: str
    reason: str = Field(
        default="Administrative action",
        min_length=1,
        max_length=100,
    )


class ServerMessageRequest(BaseModel):
    message: str = Field(
        min_length=1,
        max_length=200,
    )


###############################################################################
# Validation
###############################################################################

def validate_name(value: str) -> str:
    """
    Allow only conservative character/account names.
    """

    if not NAME_RE.fullmatch(value):
        raise HTTPException(
            status_code=400,
            detail="Invalid character name.",
        )

    return value


###############################################################################
# Worldserver console
###############################################################################

def send_worldserver_command(command: str) -> str:
    """
    Attach to the running AzerothCore console through Docker's attach API.
    """

    client = docker.APIClient(
        base_url="unix://var/run/docker.sock"
    )

    try:
        sock = client.attach_socket(
            CONTAINER_NAME,
            params={
                "stdin": 1,
                "stdout": 1,
                "stderr": 1,
                "stream": 1,
                "logs": 0,
            },
        )

    except Exception as exc:
        raise HTTPException(
            status_code=503,
            detail=f"Unable to attach to worldserver: {exc}",
        )

    raw = sock._sock

    try:
        raw.sendall(
            (command + "\n").encode("utf-8")
        )

        time.sleep(0.15)

        raw.settimeout(1.5)

        chunks = []

        while True:

            try:
                data = raw.recv(4096)

            except TimeoutError:
                break

            except OSError:
                break

            if not data:
                break

            text = data.decode(
                "utf-8",
                errors="replace",
            )

            chunks.append(text)

            if "AC>" in text:
                break

        output = "".join(chunks)

        output = ANSI_RE.sub(
            "",
            output,
        )

        output = (
            output
            .replace("\r\n", "\n")
            .replace("\r", "\n")
        )

        return output.strip()

    finally:
        sock.close()


###############################################################################
# Character DB helper
###############################################################################

def get_character_db():
    """
    Connect to the AzerothCore character database.

    This helper receives dedicated write credentials through environment
    variables. Do NOT use MySQL root credentials here.
    """

    return pymysql.connect(
        host=os.environ["WOW_DB_HOST"],
        port=int(
            os.environ.get(
                "WOW_DB_PORT",
                "3306",
            )
        ),
        user=os.environ["WOW_DB_WRITE_USER"],
        password=os.environ["WOW_DB_WRITE_PASSWORD"],
        database="acore_characters",
        cursorclass=pymysql.cursors.DictCursor,
        autocommit=True,
    )


###############################################################################
# Health / server
###############################################################################

@app.get("/health")
def health():
    return {
        "status": "ok",
        "worldserver": CONTAINER_NAME,
    }


@app.get("/server/info")
def server_info():
    return {
        "output": send_worldserver_command(
            "server info"
        ),
    }


###############################################################################
# Character level
###############################################################################

@app.post("/character/level")
def set_character_level(
    request: CharacterLevelRequest,
):
    character = validate_name(
        request.character
    )

    command = (
        f"character level "
        f"{character} "
        f"{request.level}"
    )

    return {
        "character": character,
        "level": request.level,
        "output": send_worldserver_command(
            command
        ),
    }


###############################################################################
# Character money
###############################################################################

@app.post("/character/money")
def set_character_money(
    request: CharacterMoneyRequest,
):
    """
    Set exact character money in copper.

    1 gold   = 10,000 copper
    1 silver =    100 copper
    1 copper =      1 copper

    We use the database for exact offline-safe money setting because
    AzerothCore's 'modify money' console command operates on the currently
    selected player.
    """

    conn = get_character_db()

    try:

        with conn.cursor() as cursor:

            cursor.execute(
                """
                SELECT guid, name, online, money
                FROM characters
                WHERE guid = %s
                """,
                (request.guid,),
            )

            row = cursor.fetchone()

            if not row:
                raise HTTPException(
                    status_code=404,
                    detail="Character not found.",
                )

            if row["online"]:
                raise HTTPException(
                    status_code=409,
                    detail=(
                        "Character must be offline before "
                        "changing money."
                    ),
                )

            old_money = row["money"]

            cursor.execute(
                """
                UPDATE characters
                SET money = %s
                WHERE guid = %s
                """,
                (
                    request.copper,
                    request.guid,
                ),
            )

            return {
                "guid": request.guid,
                "character": row["name"],
                "old_copper": old_money,
                "new_copper": request.copper,
            }

    finally:
        conn.close()


###############################################################################
# Reset talents
###############################################################################

@app.post("/character/reset-talents")
def reset_character_talents(
    request: CharacterNameRequest,
):
    character = validate_name(
        request.character
    )

    return {
        "character": character,
        "output": send_worldserver_command(
            f"reset talents {character}"
        ),
    }


###############################################################################
# Rename flag
###############################################################################

@app.post("/character/rename")
def rename_character(
    request: CharacterNameRequest,
):
    character = validate_name(
        request.character
    )

    return {
        "character": character,
        "output": send_worldserver_command(
            f"character rename {character}"
        ),
    }


###############################################################################
# Kick
###############################################################################

@app.post("/character/kick")
def kick_character(
    request: KickRequest,
):
    character = validate_name(
        request.character
    )

    reason = (
        request.reason
        .replace("\r", " ")
        .replace("\n", " ")
        .strip()
    )

    return {
        "character": character,
        "output": send_worldserver_command(
            f"kick {character} {reason}"
        ),
    }


###############################################################################
# Server announce
###############################################################################

@app.post("/server/announce")
def server_announce(
    request: ServerMessageRequest,
):
    message = (
        request.message
        .replace("\r", " ")
        .replace("\n", " ")
        .strip()
    )

    return {
        "output": send_worldserver_command(
            f"announce {message}"
        ),
    }
PY

###############################################################################
# Ensure helper has pymysql
###############################################################################

source "$BASE/helper/venv/bin/activate"

pip install pymysql

deactivate

###############################################################################
# Character detail routes
###############################################################################

cat >> "$WEB/main.py" <<'PY'


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
                "/run/wow-admin-helper.sock"
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
PY

###############################################################################
# Character detail template
###############################################################################

cat > "$WEB/templates/character_detail.html" <<'HTML'
<!doctype html>
<html lang="en">

<head>

    <meta charset="utf-8">

    <meta
        name="viewport"
        content="width=device-width,initial-scale=1"
    >

    <title>
        {{ character.name }} - JesterWoW Admin
    </title>

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

            <a href="/">
                Dashboard
            </a>

            <a href="/accounts">
                Accounts
            </a>

            <a
                class="active"
                href="/characters"
            >
                Characters
            </a>

            <a href="/server">
                Server
            </a>

            <a href="/audit">
                Audit Log
            </a>

        </nav>

    </aside>


    <main>

        <header>

            <div>

                <a
                    class="back-link"
                    href="/characters"
                >
                    ← Characters
                </a>

                <h1>
                    {{ character.name }}
                </h1>

                <p>
                    Account:
                    {{ character.username }}
                </p>

            </div>


            <div class="status">

                {% if character.online %}

                    <span class="dot online"></span>
                    Online

                {% else %}

                    <span class="dot offline"></span>
                    Offline

                {% endif %}

            </div>

        </header>


        <section class="cards">

            <div class="card">

                <span>Level</span>

                <strong>
                    {{ character.level }}
                </strong>

            </div>


            <div class="card">

                <span>Gold</span>

                <strong>
                    {{ character.money // 10000 }}g
                </strong>

            </div>


            <div class="card">

                <span>Played Time</span>

                <strong>
                    {{ character.totaltime // 3600 }}h
                </strong>

            </div>

        </section>


        <div class="action-grid">


            <section class="panel">

                <div class="panel-title">
                    <h2>Level</h2>
                </div>

                <form
                    class="form-area"
                    method="post"
                    action="/characters/{{ character.guid }}/level"
                >

                    <input
                        type="hidden"
                        name="character"
                        value="{{ character.name }}"
                    >

                    <label>
                        Character Level
                    </label>

                    <input
                        type="number"
                        name="level"
                        min="1"
                        max="80"
                        value="{{ character.level }}"
                        required
                    >

                    <button
                        class="primary-button"
                        type="submit"
                    >
                        Set Level
                    </button>

                </form>

            </section>


            <section class="panel">

                <div class="panel-title">
                    <h2>Money</h2>
                </div>

                <form
                    class="form-area"
                    method="post"
                    action="/characters/{{ character.guid }}/money"
                >

                    <label>
                        Gold
                    </label>

                    <input
                        type="number"
                        name="gold"
                        min="0"
                        value="{{ character.money // 10000 }}"
                    >

                    <label>
                        Silver
                    </label>

                    <input
                        type="number"
                        name="silver"
                        min="0"
                        max="99"
                        value="{{ (character.money // 100) % 100 }}"
                    >

                    <label>
                        Copper
                    </label>

                    <input
                        type="number"
                        name="copper"
                        min="0"
                        max="99"
                        value="{{ character.money % 100 }}"
                    >

                    <button
                        class="primary-button"
                        type="submit"
                        {% if character.online %}
                            disabled
                        {% endif %}
                    >
                        Set Money
                    </button>

                    {% if character.online %}

                    <small>
                        Character must be offline before money
                        can be changed safely.
                    </small>

                    {% endif %}

                </form>

            </section>


            <section class="panel">

                <div class="panel-title">
                    <h2>Character Actions</h2>
                </div>

                <div class="button-stack">


                    <form
                        method="post"
                        action="/characters/{{ character.guid }}/reset-talents"
                    >

                        <input
                            type="hidden"
                            name="character"
                            value="{{ character.name }}"
                        >

                        <button
                            class="secondary-button"
                            type="submit"
                        >
                            Reset Talents
                        </button>

                    </form>


                    <form
                        method="post"
                        action="/characters/{{ character.guid }}/rename"
                    >

                        <input
                            type="hidden"
                            name="character"
                            value="{{ character.name }}"
                        >

                        <button
                            class="secondary-button"
                            type="submit"
                        >
                            Force Rename
                        </button>

                    </form>


                    <form
                        method="post"
                        action="/characters/{{ character.guid }}/kick"
                    >

                        <input
                            type="hidden"
                            name="character"
                            value="{{ character.name }}"
                        >

                        <button
                            class="danger-button"
                            type="submit"
                            {% if not character.online %}
                                disabled
                            {% endif %}
                        >
                            Kick Player
                        </button>

                    </form>


                </div>

            </section>


        </div>

    </main>

</div>

</body>

</html>
HTML

###############################################################################
# Make character names clickable
###############################################################################

python3 - <<'PY'
from pathlib import Path

path = Path(
    "/opt/wow-admin/web/app/templates/characters.html"
)

text = path.read_text()

old = """<strong>
                            {{ char.name }}
                        </strong>"""

new = """<a class="table-link"
                           href="/characters/{{ char.guid }}">
                            {{ char.name }}
                        </a>"""

text = text.replace(
    old,
    new,
)

path.write_text(text)
PY

###############################################################################
# CSS
###############################################################################

cat >> "$WEB/static/style.css" <<'CSS'


.back-link {
    display: inline-block;

    margin-bottom: 10px;

    color: #6deaff;

    text-decoration: none;
}


.action-grid {
    display: grid;

    grid-template-columns:
        repeat(
            2,
            minmax(280px, 1fr)
        );

    gap: 20px;
}


.form-area label {
    color: #91a5c0;

    font-size: 13px;
}


.button-stack {
    display: grid;

    gap: 12px;

    padding: 20px;
}


.secondary-button,
.danger-button {
    width: 100%;

    padding: 11px 16px;

    border-radius: 9px;

    font-weight: 700;

    cursor: pointer;
}


.secondary-button {
    color: #d9f8ff;

    border:
        1px solid
        rgba(0, 225, 255, .25);

    background:
        rgba(0, 225, 255, .08);
}


.danger-button {
    color: #ff9dbb;

    border:
        1px solid
        rgba(255, 71, 126, .3);

    background:
        rgba(255, 71, 126, .08);
}


.danger-button:disabled {
    opacity: .35;

    cursor: not-allowed;
}


.table-link {
    color: #79edff;

    font-weight: 700;

    text-decoration: none;
}


.table-link:hover {
    text-shadow:
        0 0 8px
        rgba(0, 225, 255, .65);
}


@media (max-width: 900px) {

    .action-grid {
        grid-template-columns: 1fr;
    }

}
CSS

###############################################################################
# Restart helper
###############################################################################

sudo systemctl restart wow-admin-helper

###############################################################################
# Rebuild web app
###############################################################################

cd "$BASE"

docker compose build

docker compose up -d

sleep 3

echo
echo "Character actions upgrade complete."
echo
echo "Open:"
echo
echo "  http://10.20.60.18:8090/characters"
echo
echo
echo "Backup:"
echo "  $BACKUP"
