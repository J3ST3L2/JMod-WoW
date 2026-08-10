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

# JESTERWOW_ADMIN_TOOLS_HELPER
from admin_tools import router as _jesterwow_admin_tools_router
app.include_router(_jesterwow_admin_tools_router)
