"""Web UI and safe natural-language parser for JesterWoW admin tools."""

from __future__ import annotations

import http.client
import json
import socket
import re
from urllib.parse import quote_plus

from fastapi import APIRouter, Form, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from jinja2 import Environment, FileSystemLoader, select_autoescape

# Imported from the existing application. main.py loads this module only after
# defining these functions, so this does not create a second DB/helper stack.
from main import get_db

HELPER_SOCKET = "/run/wow-admin/helper.sock"


class _UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path: str):
        super().__init__("localhost")
        self._path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(self._path)


def _helper_request(method: str, path: str, payload=None):
    connection = _UnixHTTPConnection(HELPER_SOCKET)
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    headers = {} if body is None else {"Content-Type": "application/json"}
    try:
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        raw = response.read().decode("utf-8", errors="replace")
        try:
            data = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            data = {"detail": raw or f"HTTP {response.status}"}
        if response.status >= 400:
            raise RuntimeError(data.get("detail", f"Helper returned HTTP {response.status}"))
        return data
    finally:
        connection.close()


def helper_get(path: str):
    return _helper_request("GET", path)


def helper_post(path: str, payload: dict):
    return _helper_request("POST", path, payload)

router = APIRouter()
jinja = Environment(
    loader=FileSystemLoader("/app/templates"),
    autoescape=select_autoescape(["html", "xml"]),
)

ITEM_ALIASES = {
    "glacial bag": 41600,
    "glacial bags": 41600,
    "benediction": 18608,
    "belt of transcendence": 16925,
    "leggings of transcendence": 16922,
    "boots of transcendence": 16919,
    "pure elementium band": 19382,
    "cauterizing band": 19140,
    "rejuvenating gem": 19395,
    "shard of the scale": 17064,
    "essence gatherer": 19435,
}


def _client_ip(request: Request) -> str:
    forwarded = request.headers.get("x-forwarded-for", "").split(",", 1)[0].strip()
    if forwarded:
        return forwarded[:80]
    return (request.client.host if request.client else "")[:80]


def _characters():
    conn = get_db()
    try:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT guid, name, level, class, race, online
                FROM acore_characters.characters
                ORDER BY name
            """)
            return list(cur.fetchall())
    finally:
        conn.close()


def _find_character(name: str):
    conn = get_db()
    try:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT guid, name, level, class, race, online
                FROM acore_characters.characters
                WHERE LOWER(name)=LOWER(%s)
                LIMIT 1
            """, (name.strip(),))
            return cur.fetchone()
    finally:
        conn.close()


def _item_by_id(item_id: int):
    conn = get_db()
    try:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT entry, name, Quality, ItemLevel, RequiredLevel, InventoryType
                FROM acore_world.item_template
                WHERE entry=%s
                LIMIT 1
            """, (item_id,))
            return cur.fetchone()
    finally:
        conn.close()


def _find_items(query: str, limit: int = 40):
    query = query.strip()
    if not query:
        return []
    conn = get_db()
    try:
        with conn.cursor() as cur:
            if query.isdigit():
                cur.execute("""
                    SELECT entry, name, Quality, ItemLevel, RequiredLevel, InventoryType
                    FROM acore_world.item_template
                    WHERE entry=%s
                    LIMIT %s
                """, (int(query), limit))
            else:
                cur.execute("""
                    SELECT entry, name, Quality, ItemLevel, RequiredLevel, InventoryType
                    FROM acore_world.item_template
                    WHERE name LIKE %s
                    ORDER BY
                        CASE WHEN LOWER(name)=LOWER(%s) THEN 0
                             WHEN LOWER(name) LIKE LOWER(%s) THEN 1
                             ELSE 2 END,
                        ItemLevel DESC,
                        name
                    LIMIT %s
                """, (f"%{query}%", query, f"{query}%", limit))
            return list(cur.fetchall())
    finally:
        conn.close()


def _resolve_item(text: str):
    cleaned = text.strip().strip('"\'').lower()
    if cleaned in ITEM_ALIASES:
        return _item_by_id(ITEM_ALIASES[cleaned])
    if cleaned.isdigit():
        return _item_by_id(int(cleaned))
    matches = _find_items(text, limit=15)
    if not matches:
        return None
    exact = [i for i in matches if str(i["name"]).lower() == cleaned]
    if exact:
        return exact[0]
    # Only auto-pick a fuzzy result when it is unambiguous enough.
    if len(matches) == 1:
        return matches[0]
    return {"ambiguous": matches}


def _catalog_entities(entity_type: str, query: str = "", limit: int = 500):
    """Read friendly entities from JMod's local catalog using the web RO user."""
    query = query.strip()
    limit = max(1, min(int(limit), 1000))
    conn = get_db()
    try:
        with conn.cursor() as cur:
            if not query:
                cur.execute(f"""
                    SELECT game_id, name, short_description, description, required_level
                    FROM jmod.catalog_entities
                    WHERE entity_type=%s AND enabled=1
                    ORDER BY name, game_id
                    LIMIT {limit}
                """, (entity_type,))
            elif query.isdigit():
                cur.execute(f"""
                    SELECT game_id, name, short_description, description, required_level
                    FROM jmod.catalog_entities
                    WHERE entity_type=%s AND enabled=1 AND game_id=%s
                    ORDER BY name, game_id
                    LIMIT {limit}
                """, (entity_type, int(query)))
            else:
                cur.execute(f"""
                    SELECT game_id, name, short_description, description, required_level
                    FROM jmod.catalog_entities
                    WHERE entity_type=%s AND enabled=1 AND name LIKE %s
                    ORDER BY
                        CASE WHEN LOWER(name)=LOWER(%s) THEN 0
                             WHEN LOWER(name) LIKE LOWER(%s) THEN 1
                             ELSE 2 END,
                        name,
                        game_id
                    LIMIT {limit}
                """, (entity_type, f"%{query}%", query, f"{query}%"))
            return list(cur.fetchall())
    finally:
        conn.close()


def _resolve_catalog_entity(entity_type: str, text: str):
    cleaned = text.strip().strip('"\'')
    matches = _catalog_entities(entity_type, cleaned, limit=15)
    if not matches:
        return None
    if cleaned.isdigit():
        return matches[0]

    exact = [row for row in matches if str(row["name"]).lower() == cleaned.lower()]
    if len(exact) == 1:
        return exact[0]
    if len(exact) > 1:
        return {"ambiguous": exact}
    if len(matches) == 1:
        return matches[0]
    return {"ambiguous": matches}


def _render(name: str, **ctx):
    return HTMLResponse(jinja.get_template(name).render(**ctx))


def _parse_god_prompt(prompt: str):
    text = " ".join(prompt.strip().split())

    # max level Jestaj / max Jestaj
    m = re.fullmatch(r"(?i)(?:max(?:imum)?\s+level|max)\s+([A-Za-z][A-Za-z0-9_-]{1,31})", text)
    if m:
        return {"kind": "level", "character": m.group(1), "level": 80}

    # set level Jestaj 70 / set Jestaj level 70
    m = re.fullmatch(r"(?i)set\s+level\s+([A-Za-z][A-Za-z0-9_-]{1,31})\s+(\d{1,2})", text)
    if not m:
        m = re.fullmatch(r"(?i)set\s+([A-Za-z][A-Za-z0-9_-]{1,31})\s+level\s+(\d{1,2})", text)
    if m:
        return {"kind": "level", "character": m.group(1), "level": int(m.group(2))}

    # give Jestaj 4 glacial bags / give Jestaj Benediction
    m = re.fullmatch(r"(?i)(?:give|mail)\s+([A-Za-z][A-Za-z0-9_-]{1,31})\s+(.+)", text)
    if m:
        character = m.group(1)
        rest = m.group(2).strip()
        qty = 1
        qm = re.fullmatch(r"(\d{1,4})\s+(.+)", rest)
        if qm:
            qty = int(qm.group(1))
            rest = qm.group(2).strip()
        return {"kind": "item", "character": character, "count": qty, "item_text": rest}

    return {"kind": "unknown"}


@router.get("/gear", response_class=HTMLResponse)
def gear_page(request: Request, q: str = "", character: str = "", message: str = ""):
    return _render(
        "gear.html",
        characters=_characters(),
        items=_find_items(q) if q else [],
        q=q,
        selected_character=character,
        message=message,
    )


@router.post("/gear/send")
def gear_send(
    request: Request,
    character: str = Form(...),
    item_id: int = Form(...),
    count: int = Form(1),
):
    char = _find_character(character)
    item = _item_by_id(item_id)
    if not char or not item:
        return RedirectResponse("/gear?message=" + quote_plus("Character or item was not found."), status_code=303)
    count = max(1, min(int(count), 1000))
    result = helper_post("/admin-tools/character/items", {
        "character": char["name"],
        "item_id": int(item["entry"]),
        "item_name": item["name"],
        "count": count,
        "actor": "web-admin",
        "request_ip": _client_ip(request),
        "prompt": "",
    })
    msg = f'Mailed {count} x {item["name"]} to {char["name"]}.'
    if result.get("output"):
        msg += " Worldserver responded: " + result["output"][-300:]
    return RedirectResponse("/gear?character=" + quote_plus(char["name"]) + "&message=" + quote_plus(msg), status_code=303)


@router.get("/tools/god-mode", response_class=HTMLResponse)
def god_mode_page(request: Request, message: str = "", error: str = "", prompt: str = ""):
    return _render("god_mode.html", message=message, error=error, prompt=prompt)


@router.post("/tools/god-mode")
def god_mode_execute(request: Request, prompt: str = Form(...)):
    original = prompt[:500]
    parsed = _parse_god_prompt(original)

    try:
        if parsed["kind"] == "level":
            char = _find_character(parsed["character"])
            if not char:
                raise ValueError(f'Character {parsed["character"]} was not found.')
            level = int(parsed["level"])
            if level < 1 or level > 80:
                raise ValueError("Level must be between 1 and 80.")
            result = helper_post("/admin-tools/character/level", {
                "character": char["name"],
                "level": level,
                "actor": "web-admin",
                "request_ip": _client_ip(request),
                "prompt": original,
            })
            msg = f'Set {char["name"]} to level {level}. Command: {result.get("command", "")}'
            return RedirectResponse("/tools/god-mode?message=" + quote_plus(msg), status_code=303)

        if parsed["kind"] == "item":
            char = _find_character(parsed["character"])
            if not char:
                raise ValueError(f'Character {parsed["character"]} was not found.')
            item = _resolve_item(parsed["item_text"])
            if not item:
                raise ValueError(f'No item matched “{parsed["item_text"]}”.')
            if "ambiguous" in item:
                names = ", ".join(f'{x["name"]} ({x["entry"]})' for x in item["ambiguous"][:6])
                raise ValueError("That item name is ambiguous. Try an exact name or ID. Matches: " + names)
            count = max(1, min(int(parsed["count"]), 1000))
            result = helper_post("/admin-tools/character/items", {
                "character": char["name"],
                "item_id": int(item["entry"]),
                "item_name": item["name"],
                "count": count,
                "actor": "web-admin",
                "request_ip": _client_ip(request),
                "prompt": original,
            })
            msg = f'Mailed {count} x {item["name"]} to {char["name"]}. Command: {result.get("command", "")}'
            return RedirectResponse("/tools/god-mode?message=" + quote_plus(msg), status_code=303)

        raise ValueError(
            "I only execute allow-listed requests here. Try: “give Jestaj 4 glacial bags”, "
            "“give Jestaj Benediction”, “give Jestaj 18608”, “max level Jestaj”, or “set Jestaj level 70”."
        )
    except Exception as exc:
        return RedirectResponse(
            "/tools/god-mode?prompt=" + quote_plus(original) + "&error=" + quote_plus(str(exc)),
            status_code=303,
        )


@router.get("/jmod", response_class=HTMLResponse)
@router.get("/jmod-tools", response_class=HTMLResponse)
def jmod_tools_page(request: Request):
    return _render(
        "jmod_tools.html",
        characters=_characters(),
        mounts=_catalog_entities("mount", limit=500),
        message="",
        error="",
        result="",
    )


@router.post("/jmod", response_class=HTMLResponse)
@router.post("/jmod-tools", response_class=HTMLResponse)
def jmod_tools_execute(
    request: Request,
    command: str = Form(...),
    character: str = Form(""),
    value: str = Form(""),
    count: int = Form(1),
):
    payload = {
        "command": command,
        "character": character,
        "value": value,
        "count": max(1, min(int(count), 1000)),
        "actor": "web-admin",
        "request_ip": _client_ip(request),
        "prompt": f"web:{command} {character} {value}".strip(),
    }

    resolved_label = ""
    try:
        if command.strip().lower() in {"mount", "learnmount"}:
            mount = _resolve_catalog_entity("mount", value)
            if not mount:
                raise ValueError(f'No mount matched “{value}”. Try a mount name or spell ID.')
            if "ambiguous" in mount:
                choices = ", ".join(
                    f'{row["name"]} ({row["game_id"]})'
                    for row in mount["ambiguous"][:8]
                )
                raise ValueError(
                    "That mount name is ambiguous. Use a more specific name or spell ID. Matches: " + choices
                )
            payload["value"] = str(mount["game_id"])
            resolved_label = f'{mount["name"]} ({mount["game_id"]})'

        data = helper_post("/jc/execute", payload)
        if data.get("lines"):
            result_text = "\n".join(str(line) for line in data["lines"])
        elif data.get("output"):
            result_text = str(data["output"])
        else:
            result_text = json.dumps(data, indent=2, sort_keys=True)
        message = f"Executed JMod command: {data.get('canonical', data.get('command', command))}"
        if resolved_label:
            message += f" · {resolved_label}"
        error = ""
    except Exception as exc:
        result_text = ""
        message = ""
        error = str(exc)

    return _render(
        "jmod_tools.html",
        characters=_characters(),
        mounts=_catalog_entities("mount", limit=500),
        message=message,
        error=error,
        result=result_text,
    )


@router.get("/audit", response_class=HTMLResponse)
def audit_page(request: Request):
    try:
        payload = helper_get("/admin-tools/audit?limit=500")
        events = payload.get("events", [])
        error = ""
    except Exception as exc:
        events = []
        error = str(exc)
    return _render("audit_tools.html", events=events, error=error)
