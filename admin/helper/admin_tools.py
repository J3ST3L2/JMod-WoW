"""Restricted JesterWoW administration operations.

This module deliberately exposes only structured, validated operations. It is
NOT a generic console proxy. The web application never receives Docker socket
access.
"""

from __future__ import annotations

import json
import os
import re
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import docker
import pymysql
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from jc_commands import help_lines, resolve_command, resolve_item_alias


router = APIRouter()

CONTAINER_NAME = "ac-worldserver"
NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_-]{1,31}$")
AUDIT_PATH = Path("/opt/wow-admin/data/admin-audit.jsonl")
ANSI_RE = re.compile(r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")
MAX_GOLD = 214748
MAX_SPELL_ID = 4_294_967_295
MAX_LOCATION_LEN = 120
MAX_FRIENDS = 50
FRIEND_FLAG = 1


class AuditMeta(BaseModel):
    actor: str = Field(default="web-admin", max_length=80)
    request_ip: str = Field(default="", max_length=80)
    prompt: str = Field(default="", max_length=500)


class SendItemsRequest(AuditMeta):
    character: str
    item_id: int = Field(ge=1, le=4_294_967_295)
    count: int = Field(default=1, ge=1, le=1000)
    item_name: str = Field(default="", max_length=255)


class LevelRequest(AuditMeta):
    character: str
    level: int = Field(ge=1, le=80)


class FriendRequest(AuditMeta):
    character: str
    friend: str
    note: str = Field(default="", max_length=48)
    mutual: bool = True


class JCExecuteRequest(AuditMeta):
    """Structured request for the shared JMod/JesterConsole vocabulary."""

    command: str = Field(min_length=1, max_length=32)
    character: str = Field(default="", max_length=32)
    value: str = Field(default="", max_length=255)
    count: int = Field(default=1, ge=1, le=1000)


def _safe_name(value: str) -> str:
    value = value.strip()
    if not NAME_RE.fullmatch(value):
        raise HTTPException(status_code=400, detail="Invalid character name")
    return value


def _safe_location(value: str) -> str:
    value = " ".join((value or "").strip().split())
    if not value or len(value) > MAX_LOCATION_LEN:
        raise HTTPException(status_code=400, detail="Invalid teleport location")
    if "\n" in value or "\r" in value:
        raise HTTPException(status_code=400, detail="Invalid teleport location")
    return value


def _clean_output(value: str) -> str:
    value = ANSI_RE.sub("", value)
    return "\n".join(line.rstrip() for line in value.splitlines() if line.strip())[-8000:]


def _send_worldserver_command(command: str, read_seconds: float = 0.8) -> str:
    if "\n" in command or "\r" in command:
        raise HTTPException(status_code=400, detail="Invalid command payload")

    client = docker.APIClient(base_url="unix://var/run/docker.sock")
    sock = None
    chunks: list[bytes] = []
    try:
        sock = client.attach_socket(
            CONTAINER_NAME,
            params={"stdin": 1, "stdout": 1, "stderr": 1, "stream": 1, "logs": 0},
        )
        raw = sock._sock
        raw.sendall((command + "\n").encode("utf-8"))
        time.sleep(read_seconds)
        raw.settimeout(0.25)
        deadline = time.monotonic() + 1.5
        while time.monotonic() < deadline:
            try:
                data = raw.recv(65536)
            except (TimeoutError, OSError):
                break
            if not data:
                break
            chunks.append(data)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"worldserver console error: {exc}") from exc
    finally:
        if sock is not None:
            try:
                sock.close()
            except Exception:
                pass
        try:
            client.close()
        except Exception:
            pass

    return _clean_output(b"".join(chunks).decode("utf-8", errors="replace"))


def _character_db():
    return pymysql.connect(
        host=os.environ["WOW_DB_HOST"],
        port=int(os.environ.get("WOW_DB_PORT", "3306")),
        user=os.environ["WOW_DB_WRITE_USER"],
        password=os.environ["WOW_DB_WRITE_PASSWORD"],
        database="acore_characters",
        cursorclass=pymysql.cursors.DictCursor,
        autocommit=True,
    )


def _audit(event: dict[str, Any]) -> None:
    AUDIT_PATH.parent.mkdir(parents=True, exist_ok=True)
    row = {"timestamp": datetime.now(timezone.utc).isoformat(), **event}
    with AUDIT_PATH.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")


def _perform_and_audit(*, meta: AuditMeta, action: str, target: str,
                       command: str, details: dict[str, Any]) -> dict[str, Any]:
    try:
        output = _send_worldserver_command(command)
        status = "success"
        error = ""
    except Exception as exc:
        output = ""
        status = "failed"
        error = str(getattr(exc, "detail", exc))
        _audit({"actor": meta.actor, "request_ip": meta.request_ip, "action": action,
                "target": target, "prompt": meta.prompt, "command": command,
                "status": status, "details": details, "output": output, "error": error})
        raise

    _audit({"actor": meta.actor, "request_ip": meta.request_ip, "action": action,
            "target": target, "prompt": meta.prompt, "command": command,
            "status": status, "details": details, "output": output, "error": error})
    return {"ok": True, "command": command, "output": output}


def _parse_int(value: str, *, field: str, minimum: int, maximum: int) -> int:
    try:
        parsed = int(value.strip())
    except (TypeError, ValueError):
        raise HTTPException(status_code=400, detail=f"{field} must be an integer")
    if parsed < minimum or parsed > maximum:
        raise HTTPException(status_code=400, detail=f"{field} must be between {minimum} and {maximum}")
    return parsed


def _character_by_name(cursor, name: str):
    cursor.execute(
        "SELECT guid, name, online FROM characters WHERE UPPER(name)=UPPER(%s) LIMIT 1",
        (name,),
    )
    row = cursor.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail=f"Character '{name}' not found")
    return row


def _friend_row(cursor, owner_guid: int, friend_guid: int):
    cursor.execute(
        "SELECT guid, friend, flags, note FROM character_social WHERE guid=%s AND friend=%s LIMIT 1",
        (owner_guid, friend_guid),
    )
    return cursor.fetchone()


def _friend_count(cursor, owner_guid: int) -> int:
    cursor.execute(
        "SELECT COUNT(*) AS total FROM character_social WHERE guid=%s AND (flags & 1)=1",
        (owner_guid,),
    )
    return int(cursor.fetchone()["total"])


def _friend_rows_db() -> list[dict[str, Any]]:
    """Return the real AzerothCore friend list through the privileged helper."""
    conn = _character_db()
    try:
        with conn.cursor() as cursor:
            cursor.execute("""
                SELECT
                    cs.guid,
                    owner.name AS character_name,
                    cs.friend AS friend_guid,
                    friend.name AS friend_name,
                    friend.level AS friend_level,
                    friend.online AS friend_online,
                    cs.flags,
                    cs.note
                FROM character_social cs
                JOIN characters owner ON owner.guid = cs.guid
                JOIN characters friend ON friend.guid = cs.friend
                WHERE (cs.flags & %s) = %s
                ORDER BY owner.name, friend.name
            """, (FRIEND_FLAG, FRIEND_FLAG))
            return list(cursor.fetchall())
    finally:
        conn.close()


def _add_friend_direction(cursor, owner: dict, friend: dict, note: str) -> None:
    existing = _friend_row(cursor, owner["guid"], friend["guid"])
    if not existing and _friend_count(cursor, owner["guid"]) >= MAX_FRIENDS:
        raise HTTPException(status_code=409, detail=f'{owner["name"]} already has {MAX_FRIENDS} friends')

    if existing:
        cursor.execute(
            "UPDATE character_social SET flags=(flags | %s), note=%s WHERE guid=%s AND friend=%s",
            (FRIEND_FLAG, note, owner["guid"], friend["guid"]),
        )
    else:
        cursor.execute(
            "INSERT INTO character_social (guid, friend, flags, note) VALUES (%s, %s, %s, %s)",
            (owner["guid"], friend["guid"], FRIEND_FLAG, note),
        )


def _remove_friend_direction(cursor, owner: dict, friend: dict) -> bool:
    existing = _friend_row(cursor, owner["guid"], friend["guid"])
    if not existing or not (int(existing["flags"]) & FRIEND_FLAG):
        return False
    new_flags = int(existing["flags"]) & ~FRIEND_FLAG
    if new_flags:
        cursor.execute(
            "UPDATE character_social SET flags=%s WHERE guid=%s AND friend=%s",
            (new_flags, owner["guid"], friend["guid"]),
        )
    else:
        cursor.execute(
            "DELETE FROM character_social WHERE guid=%s AND friend=%s",
            (owner["guid"], friend["guid"]),
        )
    return True


def _set_gold_by_character(*, req: JCExecuteRequest, character: str, gold: int) -> dict[str, Any]:
    copper = gold * 10_000
    conn = _character_db()
    try:
        with conn.cursor() as cursor:
            cursor.execute(
                "SELECT guid, name, online, money FROM characters WHERE UPPER(name)=UPPER(%s) LIMIT 1",
                (character,),
            )
            row = cursor.fetchone()
            if not row:
                raise HTTPException(status_code=404, detail="Character not found")
            if row["online"]:
                raise HTTPException(status_code=409, detail="Character must be offline before changing gold")
            cursor.execute("UPDATE characters SET money=%s WHERE guid=%s", (copper, row["guid"]))
            details = {"guid": row["guid"], "old_copper": row["money"], "new_copper": copper,
                       "gold": gold, "delivery": "database"}
            _audit({"actor": req.actor, "request_ip": req.request_ip, "action": "SET_GOLD",
                    "target": row["name"], "prompt": req.prompt,
                    "command": "database:update characters.money", "status": "success",
                    "details": details, "output": "", "error": ""})
            return {"ok": True, "command": "gold", "character": row["name"], **details}
    finally:
        conn.close()


def _teach_spell(*, req: JCExecuteRequest, canonical: str, character: str, spell_id: int) -> dict[str, Any]:
    command = f"player learn {character} {spell_id}"
    action = "TEACH_MOUNT" if canonical == "mount" else "TRAIN_SPELL"
    result = _perform_and_audit(meta=req, action=action, target=character, command=command,
                                details={"spell_id": spell_id, "source": "jc"})
    return {"canonical": canonical, "character": character, "spell_id": spell_id, **result}


def _teleport_character(*, req: JCExecuteRequest, character: str, location: str) -> dict[str, Any]:
    location = _safe_location(location)
    command = f"teleport name {character} {location}"
    result = _perform_and_audit(meta=req, action="TELEPORT_PLAYER", target=character,
                                command=command, details={"location": location, "source": "jc"})
    return {"canonical": "teleport", "character": character, "location": location, **result}


@router.get("/admin-tools/friends")
def list_friends():
    return {"friends": _friend_rows_db()}


@router.post("/admin-tools/friends/add")
def add_friend(req: FriendRequest):
    character = _safe_name(req.character)
    friend_name = _safe_name(req.friend)
    note = req.note.strip()[:48]
    if character.lower() == friend_name.lower():
        raise HTTPException(status_code=400, detail="A character cannot add itself as a friend")

    conn = _character_db()
    try:
        with conn.cursor() as cursor:
            owner = _character_by_name(cursor, character)
            friend = _character_by_name(cursor, friend_name)
            _add_friend_direction(cursor, owner, friend, note)
            if req.mutual:
                _add_friend_direction(cursor, friend, owner, note)
            details = {"friend": friend["name"], "friend_guid": friend["guid"],
                       "mutual": req.mutual, "note": note, "source": "character_social"}
            _audit({"actor": req.actor, "request_ip": req.request_ip, "action": "ADD_FRIEND",
                    "target": owner["name"], "prompt": req.prompt,
                    "command": "database:update character_social", "status": "success",
                    "details": details, "output": "", "error": ""})
            return {"ok": True, "character": owner["name"], **details}
    finally:
        conn.close()


@router.post("/admin-tools/friends/remove")
def remove_friend(req: FriendRequest):
    character = _safe_name(req.character)
    friend_name = _safe_name(req.friend)
    conn = _character_db()
    try:
        with conn.cursor() as cursor:
            owner = _character_by_name(cursor, character)
            friend = _character_by_name(cursor, friend_name)
            removed = _remove_friend_direction(cursor, owner, friend)
            reverse_removed = _remove_friend_direction(cursor, friend, owner) if req.mutual else False
            details = {"friend": friend["name"], "friend_guid": friend["guid"],
                       "mutual": req.mutual, "removed": removed,
                       "reverse_removed": reverse_removed, "source": "character_social"}
            _audit({"actor": req.actor, "request_ip": req.request_ip, "action": "REMOVE_FRIEND",
                    "target": owner["name"], "prompt": req.prompt,
                    "command": "database:update character_social", "status": "success",
                    "details": details, "output": "", "error": ""})
            return {"ok": True, "character": owner["name"], **details}
    finally:
        conn.close()


@router.post("/admin-tools/character/items")
def send_items(req: SendItemsRequest):
    character = _safe_name(req.character)
    command = f'send items {character} "Admin delivery" "Delivered by JesterWoW Admin Console" {req.item_id}:{req.count}'
    return _perform_and_audit(meta=req, action="SEND_ITEM", target=character, command=command,
                              details={"item_id": req.item_id, "item_name": req.item_name,
                                       "count": req.count, "delivery": "mail"})


@router.post("/admin-tools/character/level")
def set_level(req: LevelRequest):
    character = _safe_name(req.character)
    command = f"character level {character} {req.level}"
    return _perform_and_audit(meta=req, action="SET_LEVEL", target=character, command=command,
                              details={"level": req.level})


@router.post("/jc/execute")
def execute_jc(req: JCExecuteRequest):
    canonical, spec = resolve_command(req.command)
    if canonical is None or spec is None:
        raise HTTPException(status_code=404, detail="Unknown JMod command")
    if canonical == "help":
        return {"ok": True, "command": "help", "lines": help_lines()}
    if canonical == "info":
        result = _perform_and_audit(meta=req, action="SERVER_INFO", target="server",
                                    command="server info", details={"source": "jc"})
        return {"canonical": canonical, **result}
    if canonical not in {"item", "level", "gold", "mount", "train", "teleport"}:
        raise HTTPException(status_code=501, detail=f"Command '{canonical}' is registered but not executable yet")

    character = _safe_name(req.character)
    if canonical == "level":
        level = _parse_int(req.value, field="level", minimum=1, maximum=80)
        command = f"character level {character} {level}"
        result = _perform_and_audit(meta=req, action="SET_LEVEL", target=character,
                                    command=command, details={"level": level, "source": "jc"})
        return {"canonical": canonical, "character": character, "level": level, **result}
    if canonical == "gold":
        gold = _parse_int(req.value, field="gold", minimum=0, maximum=MAX_GOLD)
        result = _set_gold_by_character(req=req, character=character, gold=gold)
        return {"canonical": canonical, **result}
    if canonical == "teleport":
        return _teleport_character(req=req, character=character, location=req.value)
    if canonical in {"mount", "train"}:
        spell_id = _parse_int(req.value, field="spell id", minimum=1, maximum=MAX_SPELL_ID)
        return _teach_spell(req=req, canonical=canonical, character=character, spell_id=spell_id)

    alias = resolve_item_alias(req.value)
    if alias:
        item_id = int(alias["id"])
        count = req.count if req.count != 1 else int(alias.get("count", 1))
        item_name = str(alias.get("label", req.value))
    else:
        item_id = _parse_int(req.value, field="item id", minimum=1, maximum=4_294_967_295)
        count = req.count
        item_name = ""

    command = f'send items {character} "Admin delivery" "Delivered by JMod /jc" {item_id}:{count}'
    result = _perform_and_audit(meta=req, action="SEND_ITEM", target=character, command=command,
                                details={"item_id": item_id, "item_name": item_name,
                                         "count": count, "delivery": "mail", "source": "jc"})
    return {"canonical": canonical, "character": character, "item_id": item_id,
            "item_name": item_name, "count": count, **result}


@router.get("/admin-tools/audit")
def get_audit(limit: int = 250):
    limit = max(1, min(int(limit), 1000))
    if not AUDIT_PATH.exists():
        return {"events": []}
    lines = AUDIT_PATH.read_text(encoding="utf-8", errors="replace").splitlines()[-limit:]
    events = []
    for line in reversed(lines):
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return {"events": events}
